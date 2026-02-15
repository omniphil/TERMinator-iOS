#ifndef SFTP_INTERNAL_H
#define SFTP_INTERNAL_H

typedef struct sftp_tx_pkt {
	uint32_t sz;
	uint32_t used;
	uint8_t type;
	uint8_t data[];
} *sftp_tx_pkt_t;

typedef struct sftp_rx_pkt {
	uint32_t cur;
	uint32_t sz;
	uint32_t used;
	uint32_t len;
	uint8_t type;
	uint8_t data[];
} *sftp_rx_pkt_t;

typedef struct sftp_string {
	uint32_t len;
	uint8_t c_str[];
} *sftp_str_t;

#endif
