/* 自动生成：guest 内回环 TLS echo 服务端的自签证书与私钥。
 * 生成命令：openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
 *                -subj "/CN=ex09-local" -keyout ex09_local.key -out ex09_local.crt
 * 仅限离线 QEMU 教学演示内嵌，严禁用于生产。 */
#pragma once

static const char TLS_LOCAL_CERT_PEM[] =
"-----BEGIN CERTIFICATE-----\n"
"MIIDCzCCAfOgAwIBAgIUA32SeqqHyzWFc2X5e046+EqeoD4wDQYJKoZIhvcNAQEL\n"
"BQAwFTETMBEGA1UEAwwKZXgwOS1sb2NhbDAeFw0yNjA4MjcwNTI1MzlaFw0yNjA5\n"
"MjYwNTI1MzlaMBUxEzARBgNVBAMMCmV4MDktbG9jYWwwggEiMA0GCSqGSIb3DQEB\n"
"AQUAA4IBDwAwggEKAoIBAQC/bnAj4vpaB/80Iz1KwAKe39ryxG8gKN1IHZmpUyyn\n"
"7EdvbRFwmvXnPjQtRghz6sf+cEGngglVd9cWUKW/6TWv4YT0B1ixdGQx3xoxXOa1\n"
"b/XNVhSDwa06uJOKjSZFpV1OdTEwKFXnZ29RjSS23HX+BjkJoVycozUIWmu41czw\n"
"7CNruG4s2sFDdwsVloBu/EqewQnSbfbgfQHgKGZKqnOsFicDAAyz7jFaxBGPDCg2\n"
"OsPzH7w0+gugKI+lNr6LADJ4006ZQt9bhrjhdq9KZESyz+i8ulgeBj3v/503LsAM\n"
"XC9mOrosq1zjdNMwq1ylRtd444bEzVBd7uwFAphzwmJfAgMBAAGjUzBRMB0GA1Ud\n"
"DgQWBBQD3c6pu6Z1lj9NaYx0BT1enApRJjAfBgNVHSMEGDAWgBQD3c6pu6Z1lj9N\n"
"aYx0BT1enApRJjAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQAI\n"
"dzQK03hZkrJbotBVQHY0dfblVFt2TtjxFsLHGRU0mrl5Ab8d8Vd4nmHIeVon6ACd\n"
"tyk5Pqw7d8rSI/vviT8eivEbEGL3DA97n3zSuWv7WP0yd2zdp4f4w35g8qJP5bwS\n"
"3MWfnPc98gjmDmJb1gxlqlQD7J0W+GQOPb0c0rJm9jtlQmIFAOA2kmFzIHjNgCv3\n"
"fu6hOw3GOnIcpFwSqRKmJpV4mk85emOdW/otagmmzB1ua1A+LcTtUwYEdMLEIMJq\n"
"I1mewbhyCScGr0liEh1rzy7TPn3lKHmFqagMsRDC6ZSB3p6K8I+iw3vezldscfiY\n"
"kUjl4reI5vLtKZk/Er/8\n"
"-----END CERTIFICATE-----\n";

static const char TLS_LOCAL_KEY_PEM[] =
"-----BEGIN PRIVATE KEY-----\n"
"MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC/bnAj4vpaB/80\n"
"Iz1KwAKe39ryxG8gKN1IHZmpUyyn7EdvbRFwmvXnPjQtRghz6sf+cEGngglVd9cW\n"
"UKW/6TWv4YT0B1ixdGQx3xoxXOa1b/XNVhSDwa06uJOKjSZFpV1OdTEwKFXnZ29R\n"
"jSS23HX+BjkJoVycozUIWmu41czw7CNruG4s2sFDdwsVloBu/EqewQnSbfbgfQHg\n"
"KGZKqnOsFicDAAyz7jFaxBGPDCg2OsPzH7w0+gugKI+lNr6LADJ4006ZQt9bhrjh\n"
"dq9KZESyz+i8ulgeBj3v/503LsAMXC9mOrosq1zjdNMwq1ylRtd444bEzVBd7uwF\n"
"AphzwmJfAgMBAAECggEAQJghWtqiI3MDWDJz4h88QyPCG5zQ6ocfc9AZI5ufO+Js\n"
"kFq7QcXoJ+lDbettur+EUITMgptMTvyrJSp9Y25r4Tc1x6oa8XYWwQVJL1LrvllT\n"
"FcBwF61oqKHTlzLdsS6Fd43v1RInOngahegcdV+aqOaspGVAfNJNeM4Z/zqVds2B\n"
"nA2rym7tGK14pcx/upNAlTzfmOQpiV1uSAxHDLi1/+4oapBARtc9y9Z8R9XkqKKU\n"
"Fv1YteA+Pg7UFsKk91TPRpjhb+BvxxvRiSKIR1K35ncGPYXO4ThX9T27dSfp1uBt\n"
"ogQQEf0ossXut9e90pusgdsP7Cmp87eUAXyOPKER0QKBgQDv9iOqcs3G7PlSl5wA\n"
"ifNqJiGWdvDs30nS2A/hnHLqvmnUp+RsweAP2Uo+iK1UneXQuQjByGxFxCcXABPc\n"
"sOyNMOv6DCyte4k9OEOVcTTOzs+1weTUhsEG2NSFPiulsjQToBCrteIkNmv5KOlT\n"
"Cei6B/uFumgntQnjYz+ebIQ9NQKBgQDMOey/MAdhX0hWlmof3iWegNkvFSc09WF+\n"
"Sh73FwJSTbtpzSCjoyf8MbYc2vT9VVYrNxwNWU2FytBiv1BDyc2OIo5ySywZ8LYM\n"
"oefcfskWiKz08n+c1rHbgMWJnonXJ1s/PSxHNfecjsRBhpVbSSh1CInkBBo2R93t\n"
"1PIkXGgXwwKBgE/B+TLTO9BNvcUU/VY0hAKZL/rKB+RDh08cX5L2pD+gEJ8NOuBn\n"
"RGkgKQxF8463eMZ6ag225z39J5z+epuU9tsrEpQm7cav0/rUM6p9WTcQCHv6OWvm\n"
"akwzT9gFxQ4rACIxxri8GLE+oX7MeVkPZxpGQvS885eXFfVNbLzkhsOtAoGAeJf/\n"
"x4mp4gKsqYyaUAUSe70kAhxgkXIQRs2n6Uop8cW61CfvjREr7EzCd9mHbwx0HIKn\n"
"Su6fy1BOqvDDibPhcHvRV4YyHYM5TM5SJq6rOWYtk1qapldUoQQyISh/xo+T3wzV\n"
"V5tzgnv/QZ4iFcxmWm1XV1Bg1gqr7uOetH/oa5cCgYEA53dR9Sxz5/HZ+3IJNYQ4\n"
"vByG7OiGXRKUdtaQx3ngTOOcFoAVRtWHkBvy0INS3CBEvF6dmLjuYbdVnKFk2AGw\n"
"N9FBbNxCdyxVMqmph8467Fc7vHmkK0h8mMi8AC+7KTRDPnf35VAFuvhNSaZLJxrf\n"
"2guYR8K+3J8mx0t+j0yRqUQ=\n"
"-----END PRIVATE KEY-----\n";
