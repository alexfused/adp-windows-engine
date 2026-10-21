/* SPDX-License-Identifier: MIT
 * Headless check that Wine's crypto works on the engine's own GnuTLS (lib/ext): Wine's bcrypt does
 * RSA and AES through GnuTLS, and its schannel builds TLS sessions with it. No network: the
 * ClientHello is only produced, not sent.
 *   1. RSA-2048 key pair, PKCS#1 SHA-256 signature, verify; a changed signature must not verify
 *   2. AES-128 ECB on the FIPS-197 appendix C.1 vector
 *   3. schannel: credentials + the first InitializeSecurityContext call -> a TLS handshake record
 * Prints "crypto ok: ..." and exits 0, or "FAIL ..." and exits 1.
 * Build: x86_64-w64-mingw32-clang -O2 tls-check.c -lbcrypt -lsecur32 -o tls-check-x86_64.exe */
#define SECURITY_WIN32
#include <windows.h>
#include <bcrypt.h>
#include <security.h>
#include <schannel.h>
#include <stdio.h>
#include <string.h>

static int fail(const char *what, long st) { printf("FAIL %s: 0x%08lx\n", what, (unsigned long)st); return 1; }

int main(void) {
    BCRYPT_ALG_HANDLE rsa, aes;
    BCRYPT_KEY_HANDLE key, akey;
    NTSTATUS st;
    UCHAR digest[32], sig[256];
    ULONG siglen = 0, n = 0;
    for (int i = 0; i < 32; i++) digest[i] = (UCHAR)(i * 7 + 1);

    if ((st = BCryptOpenAlgorithmProvider(&rsa, BCRYPT_RSA_ALGORITHM, NULL, 0))) return fail("open RSA", st);
    if ((st = BCryptGenerateKeyPair(rsa, &key, 2048, 0))) return fail("generate RSA-2048", st);
    if ((st = BCryptFinalizeKeyPair(key, 0))) return fail("finalize RSA-2048", st);
    BCRYPT_PKCS1_PADDING_INFO pad = { BCRYPT_SHA256_ALGORITHM };
    if ((st = BCryptSignHash(key, &pad, digest, sizeof digest, sig, sizeof sig, &siglen, BCRYPT_PAD_PKCS1))) return fail("RSA sign", st);
    if ((st = BCryptVerifySignature(key, &pad, digest, sizeof digest, sig, siglen, BCRYPT_PAD_PKCS1))) return fail("RSA verify", st);
    sig[10] ^= 0x40;
    if (!BCryptVerifySignature(key, &pad, digest, sizeof digest, sig, siglen, BCRYPT_PAD_PKCS1)) return fail("a changed RSA signature verified", 0);

    static const UCHAR k[16] = {0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f};
    static const UCHAR pt[16] = {0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff};
    static const UCHAR ct[16] = {0x69,0xc4,0xe0,0xd8,0x6a,0x7b,0x04,0x30,0xd8,0xcd,0xb7,0x80,0x70,0xb4,0xc5,0x5a};
    UCHAR out[16];
    if ((st = BCryptOpenAlgorithmProvider(&aes, BCRYPT_AES_ALGORITHM, NULL, 0))) return fail("open AES", st);
    if ((st = BCryptSetProperty(aes, BCRYPT_CHAINING_MODE, (PUCHAR)BCRYPT_CHAIN_MODE_ECB, sizeof(BCRYPT_CHAIN_MODE_ECB), 0))) return fail("AES ECB mode", st);
    if ((st = BCryptGenerateSymmetricKey(aes, &akey, NULL, 0, (PUCHAR)k, sizeof k, 0))) return fail("AES key", st);
    if ((st = BCryptEncrypt(akey, (PUCHAR)pt, sizeof pt, NULL, NULL, 0, out, sizeof out, &n, 0))) return fail("AES encrypt", st);
    if (n != 16 || memcmp(out, ct, 16)) return fail("AES-128 result differs from FIPS-197 C.1", 0);

    SCHANNEL_CRED cred = { .dwVersion = SCHANNEL_CRED_VERSION,
                           .dwFlags = SCH_CRED_NO_DEFAULT_CREDS | SCH_CRED_MANUAL_CRED_VALIDATION };
    CredHandle hcred; CtxtHandle ctx; TimeStamp expiry; ULONG attrs = 0;
    SECURITY_STATUS ss = AcquireCredentialsHandleA(NULL, (SEC_CHAR *)UNISP_NAME_A, SECPKG_CRED_OUTBOUND, NULL, &cred, NULL, NULL, &hcred, &expiry);
    if (ss != SEC_E_OK) return fail("schannel credentials", ss);
    SecBuffer ob = { 0, SECBUFFER_TOKEN, NULL };
    SecBufferDesc od = { SECBUFFER_VERSION, 1, &ob };
    ss = InitializeSecurityContextA(&hcred, NULL, (SEC_CHAR *)"example.invalid",
                                    ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_CONFIDENTIALITY | ISC_REQ_STREAM | ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT,
                                    0, 0, NULL, 0, &ctx, &od, &attrs, &expiry);
    if (ss != SEC_I_CONTINUE_NEEDED) return fail("schannel ClientHello", ss);
    const UCHAR *rec = ob.pvBuffer;
    if (ob.cbBuffer < 50 || rec[0] != 0x16 || rec[1] != 0x03 || rec[5] != 0x01) return fail("schannel token is not a TLS ClientHello", ob.cbBuffer);
    printf("crypto ok: RSA-2048 PKCS#1 sign/verify, AES-128 FIPS-197 vector, schannel ClientHello %lu bytes (record 0x16 0x03%02x)\n",
           (unsigned long)ob.cbBuffer, rec[2]);
    FreeContextBuffer(ob.pvBuffer);
    DeleteSecurityContext(&ctx);
    FreeCredentialsHandle(&hcred);
    BCryptDestroyKey(akey); BCryptDestroyKey(key);
    BCryptCloseAlgorithmProvider(aes, 0); BCryptCloseAlgorithmProvider(rsa, 0);
    return 0;
}
