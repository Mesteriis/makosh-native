#ifndef MAKOSH_MAIL_TLS_H
#define MAKOSH_MAIL_TLS_H
#include <stddef.h>
typedef struct MailTLS MailTLS;
MailTLS *mail_tls_create(const char *hostname, const char *ca_file);
void mail_tls_free(MailTLS *s);
int mail_tls_feed(MailTLS *s, const void *data, size_t count);
int mail_tls_handshake(MailTLS *s);
int mail_tls_encrypt(MailTLS *s, const void *data, size_t count, size_t *written);
int mail_tls_decrypt(MailTLS *s, void *data, size_t capacity, size_t *count);
int mail_tls_drain(MailTLS *s, void *data, size_t capacity);
#endif
