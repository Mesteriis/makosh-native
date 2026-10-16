#include "MailTLS.h"
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>
#include <Security/Security.h>
struct MailTLS { SSL_CTX *context; SSL *ssl; char *hostname; };

static int append_certificate(CFMutableArrayRef chain, X509 *certificate) {
    unsigned char *der = NULL;
    int length = certificate ? i2d_X509(certificate, &der) : 0;
    if (length <= 0 || !der) return 0;
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, der, length);
    OPENSSL_free(der);
    if (!data) return 0;
    SecCertificateRef value = SecCertificateCreateWithData(kCFAllocatorDefault, data);
    CFRelease(data);
    if (!value) return 0;
    CFArrayAppendValue(chain, value); CFRelease(value); return 1;
}
/* System trust, hostname, server purpose and validity are evaluated by macOS.
 * No Homebrew CA paths or process-controlled SSL_CERT_FILE roots are consulted.
 * Evaluation stays on the account's NIO executor and cannot fetch network data. */
static int verify_system_chain(X509_STORE_CTX *store, void *argument) {
    MailTLS *session = argument;
    int trusted = 0;
    CFMutableArrayRef chain = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    CFStringRef hostname = NULL;
    SecPolicyRef policy = NULL;
    SecTrustRef trust = NULL;
    CFErrorRef error = NULL;
    if (!chain || !append_certificate(chain, X509_STORE_CTX_get0_cert(store))) goto done;
    STACK_OF(X509) *untrusted = X509_STORE_CTX_get0_untrusted(store);
    for (int i = 0; i < sk_X509_num(untrusted); i++) {
        X509 *value = sk_X509_value(untrusted, i);
        if (value != X509_STORE_CTX_get0_cert(store) && !append_certificate(chain, value)) goto done;
    }
    hostname = CFStringCreateWithCString(kCFAllocatorDefault, session->hostname, kCFStringEncodingUTF8);
    if (!hostname) goto done;
    policy = SecPolicyCreateSSL(true, hostname);
    if (!policy || SecTrustCreateWithCertificates(chain, policy, &trust) != errSecSuccess || !trust) goto done;
    if (SecTrustSetNetworkFetchAllowed(trust, false) != errSecSuccess) goto done;
    trusted = SecTrustEvaluateWithError(trust, &error);
done:
    if (error) CFRelease(error);
    if (trust) CFRelease(trust);
    if (policy) CFRelease(policy);
    if (hostname) CFRelease(hostname);
    if (chain) CFRelease(chain);
    X509_STORE_CTX_set_error(store, trusted ? X509_V_OK : X509_V_ERR_CERT_REJECTED);
    return trusted;
}
MailTLS *mail_tls_create(const char *hostname, const char *ca_file) {
    if (!hostname || !*hostname) return NULL;
    MailTLS *s = calloc(1,sizeof(*s));
    if (!s) return NULL;
    s->hostname = strdup(hostname);
    if (!s->hostname) goto fail;
    s->context = SSL_CTX_new(TLS_client_method());
    if (!s->context || SSL_CTX_set_min_proto_version(s->context,TLS1_2_VERSION)!=1) goto fail;
    SSL_CTX_set_verify(s->context,SSL_VERIFY_PEER,NULL);
    if (ca_file) {
        if (SSL_CTX_load_verify_locations(s->context,ca_file,NULL)!=1) goto fail;
    } else { SSL_CTX_set_cert_verify_callback(s->context, verify_system_chain, s); }
    s->ssl=SSL_new(s->context);
    if (!s->ssl || SSL_set_tlsext_host_name(s->ssl,hostname)!=1) goto fail;
    unsigned char ip[16];
    if (inet_pton(AF_INET,hostname,ip)==1 || inet_pton(AF_INET6,hostname,ip)==1) {
        if (X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(s->ssl),hostname)!=1) goto fail;
    } else if (SSL_set1_host(s->ssl,hostname)!=1) goto fail;
    BIO *in=BIO_new(BIO_s_mem()), *out=BIO_new(BIO_s_mem());
    if (!in || !out) { BIO_free(in); BIO_free(out); goto fail; }
    SSL_set_bio(s->ssl,in,out); SSL_set_connect_state(s->ssl); return s;
fail: mail_tls_free(s); return NULL;
}
void mail_tls_free(MailTLS *s) { if (s) { SSL_free(s->ssl); SSL_CTX_free(s->context); free(s->hostname); free(s); } }
static int result(MailTLS *s,int rc) {
    if (rc==1) return 1;
    int err=SSL_get_error(s->ssl,rc);
    return err==SSL_ERROR_WANT_READ || err==SSL_ERROR_WANT_WRITE ? 0 : -1;
}
int mail_tls_feed(MailTLS *s,const void *data,size_t count) {
    if (!s || count>1024*1024) return -1;
    return BIO_write(SSL_get_rbio(s->ssl),data,(int)count)==(int)count ? 1 : -1;
}
int mail_tls_handshake(MailTLS *s) { ERR_clear_error(); return result(s,SSL_do_handshake(s->ssl)); }
int mail_tls_encrypt(MailTLS *s,const void *data,size_t count,size_t *written) { ERR_clear_error(); return result(s,SSL_write_ex(s->ssl,data,count,written)); }
int mail_tls_decrypt(MailTLS *s,void *data,size_t capacity,size_t *count) { ERR_clear_error(); return result(s,SSL_read_ex(s->ssl,data,capacity,count)); }
int mail_tls_drain(MailTLS *s,void *data,size_t capacity) { return BIO_read(SSL_get_wbio(s->ssl),data,(int)capacity); }
