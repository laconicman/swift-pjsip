/* Start from the upstream sample configuration */
#define PJ_CONFIG_IPHONE 1
#include <pj/config_site_sample.h>

#define PJMEDIA_HAS_VIDEO                 1

/* Enable iOS video device backend */
#define PJMEDIA_VIDEO_DEV_HAS_IOS         1

/* Enable VideoToolbox codec. On iOS would require VideoToolbox.framework */
#define PJMEDIA_HAS_VID_TOOLBOX_CODEC 1

/* Enable UDP transport */
#define PJSIP_HAS_UDP_TRANSPORT 1

/* Enable TCP transport */
#define PJSIP_HAS_TCP_TRANSPORT 1

/* Enable TLS transport */
#define PJSIP_HAS_TLS_TRANSPORT 1
#define PJ_HAS_SSL_SOCK 1
#undef PJ_SSL_SOCK_IMP
#define PJ_SSL_SOCK_IMP PJ_SSL_SOCK_IMP_APPLE

/* Increase SIP message buffer */
#define PJSIP_MAX_PKT_LEN  16000  // or 12288; default is ~4000

/* Disable switching to TCP */
#define PJSIP_DONT_SWITCH_TO_TCP 1

/* Enable 729 Audio Codec */
#define PJMEDIA_HAS_INTEL_IPP_CODEC_G729     0
#define PJMEDIA_HAS_BCG729 1

/* Satisfy legacy infrastructure */
#define PJMEDIA_RTP_PT_TELEPHONE_EVENTS  101