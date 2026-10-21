/* SPDX-License-Identifier: MIT
 * Console test program for test-on-intel.sh, built twice by archive.sh with llvm-mingw:
 * hello32.exe (i386: runs through WoW64) and hello64.exe (x86_64). It is never run on the build Mac.
 * Prints one line per check and exits 0 only if all pass:
 *   arch     which code this is and what Windows reports (IsWow64Process2)
 *   execmem  PAGE_EXECUTE_READWRITE memory written and called, as JITs and packers do
 *            (needs the loader's allow-unsigned-executable-memory entitlement)
 *   context  SuspendThread + GetThreadContext on a second thread (wineserver's Mach thread calls)
 *   tls      schannel client credentials: schannel exists only if Wine loaded GnuTLS from lib/ext
 *            (@loader_path/../../ext/libgnutls.30.dylib); no network is used
 *   fonts    Tahoma (Wine's own font) found and measured: win32u loaded FreeType from lib/ext
 * Link: -lsecur32 -lgdi32.
 */
#define SECURITY_WIN32
#include <windows.h>
#include <security.h>
#include <schannel.h>
#include <stdio.h>
#include <string.h>

static DWORD WINAPI spin(void *arg)
{
    volatile LONG *stop = arg;
    while (!*stop) Sleep(1);
    return 0;
}

static int CALLBACK count_family(const LOGFONTW *lf, const TEXTMETRICW *tm, DWORD type, LPARAM param)
{
    (void)lf; (void)tm; (void)type;
    (*(int *)param)++;
    return 1;
}

static int check_tls(void)
{
    CredHandle cred;
    TimeStamp expiry;
    SCHANNEL_CRED sc;
    SECURITY_STATUS st;

    memset(&sc, 0, sizeof(sc));
    sc.dwVersion = SCHANNEL_CRED_VERSION;
    sc.dwFlags = SCH_CRED_NO_DEFAULT_CREDS | SCH_CRED_MANUAL_CRED_VALIDATION;
    st = AcquireCredentialsHandleW(NULL, (SEC_WCHAR *)UNISP_NAME_W, SECPKG_CRED_OUTBOUND, NULL, &sc, NULL, NULL,
                                   &cred, &expiry);
    if (st != SEC_E_OK)
    {
        printf("tls: FAILED (AcquireCredentialsHandle 0x%08lx%s)\n", (unsigned long)st,
               st == SEC_E_SECPKG_NOT_FOUND ? ": no schannel, GnuTLS did not load" : "");
        return 1;
    }
    FreeCredentialsHandle(&cred);
    printf("tls: ok (schannel client credentials, GnuTLS loaded)\n");
    return 0;
}

static int check_fonts(void)
{
    HDC dc = CreateCompatibleDC(NULL);
    LOGFONTW lf;
    HFONT font, old;
    SIZE size = { 0, 0 };
    WCHAR face[LF_FACESIZE] = { 0 };
    int families = 0, tahoma = 0;

    if (!dc) { printf("fonts: FAILED (CreateCompatibleDC error %lu)\n", GetLastError()); return 1; }
    memset(&lf, 0, sizeof(lf));
    lf.lfCharSet = DEFAULT_CHARSET;
    EnumFontFamiliesExW(dc, &lf, count_family, (LPARAM)&families, 0);
    wcscpy(lf.lfFaceName, L"Tahoma");
    EnumFontFamiliesExW(dc, &lf, count_family, (LPARAM)&tahoma, 0);
    font = CreateFontW(-16, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, 0, 0, L"Tahoma");
    old = SelectObject(dc, font);
    GetTextFaceW(dc, LF_FACESIZE, face);
    GetTextExtentPoint32W(dc, L"Hello, Intel", 12, &size);
    SelectObject(dc, old);
    DeleteObject(font);
    DeleteDC(dc);
    if (tahoma && size.cx > 0 && !wcscmp(face, L"Tahoma"))
    {
        printf("fonts: ok (%d families, Tahoma text %ldx%ld)\n", families, size.cx, size.cy);
        return 0;
    }
    printf("fonts: FAILED (%d families, Tahoma %s, selected face \"%ls\", text %ldx%ld: FreeType did not load?)\n",
           families, tahoma ? "found" : "missing", face, size.cx, size.cy);
    return 1;
}

int main(void)
{
    typedef BOOL (WINAPI *wow2_fn)(HANDLE, USHORT *, USHORT *);
    wow2_fn wow2 = (wow2_fn)GetProcAddress(GetModuleHandleA("kernel32.dll"), "IsWow64Process2");
    USHORT process_machine = 0, native_machine = 0;
    BOOL wow64 = FALSE;
    int failures = 0;

    IsWow64Process(GetCurrentProcess(), &wow64);
    if (wow2) wow2(GetCurrentProcess(), &process_machine, &native_machine);
    printf("arch: %s code, pointer %u bytes, wow64=%d, process machine 0x%04x, native machine 0x%04x\n",
           sizeof(void *) == 8 ? "x86_64" : "i386", (unsigned)sizeof(void *), wow64, process_machine, native_machine);
#ifndef _WIN64
    if (!wow64) { printf("arch: FAILED (a 32-bit program should run under WoW64)\n"); failures++; }
#endif

    /* mov eax, 42 ; ret */
    static const unsigned char code[] = { 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    unsigned char *mem = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!mem) { printf("execmem: FAILED (VirtualAlloc error %lu)\n", GetLastError()); failures++; }
    else
    {
        int (*fn)(void);
        memcpy(mem, code, sizeof(code));
        FlushInstructionCache(GetCurrentProcess(), mem, sizeof(code));
        fn = (int (*)(void))mem;
        int r = fn();
        printf("execmem: %s (returned %d)\n", r == 42 ? "ok" : "FAILED", r);
        if (r != 42) failures++;
        VirtualFree(mem, 0, MEM_RELEASE);
    }

    volatile LONG stop = 0;
    HANDLE thread = CreateThread(NULL, 0, spin, (void *)&stop, 0, NULL);
    CONTEXT ctx;
    DWORD suspended;
    BOOL got;
    Sleep(50);
    memset(&ctx, 0, sizeof(ctx));
    ctx.ContextFlags = CONTEXT_CONTROL;
    suspended = SuspendThread(thread);
    got = GetThreadContext(thread, &ctx);
    ResumeThread(thread);
    stop = 1;
    WaitForSingleObject(thread, 5000);
    CloseHandle(thread);
#ifdef _WIN64
    printf("context: %s (suspend count %lu, rip %p)\n", got ? "ok" : "FAILED", suspended, (void *)ctx.Rip);
#else
    printf("context: %s (suspend count %lu, eip %p)\n", got ? "ok" : "FAILED", suspended, (void *)ctx.Eip);
#endif
    if (!got || suspended == (DWORD)-1) failures++;

    failures += check_tls();
    failures += check_fonts();

    printf("result: %s\n", failures ? "FAILED" : "all passed");
    return failures ? 1 : 0;
}
