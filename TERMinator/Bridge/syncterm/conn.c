/* Copyright (C), 2007 by Stephen Hurd */

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

#include "ciolib.h"
#include "gen_defs.h"
#include "genwrap.h"
#include "sockwrap.h"
#include "threadwrap.h"

#ifdef _WIN32
 #undef socklen_t

// Borland hack (broken header)
 #ifdef __BORLANDC__
  #define _MSC_VER 1
 #endif
 #include "ws2tcpip.h"
 #ifdef __BORLANDC__
  #undef _MSC_VER
 #endif
 #ifndef AI_ADDRCONFIG
  #define AI_ADDRCONFIG 0x0400 // Vista or later.
 #endif
 #ifndef AI_NUMERICSERV
  #define AI_NUMERICSERV 0     // No supported by Windows
 #endif
#endif /* ifdef _WIN32 */

#include "bbslist.h"
#include "conn.h"
#include "raw.h"
#include "rlogin.h"
#include "uifcinit.h"
#ifndef WITHOUT_CRYPTLIB
 #include "ssh.h"
 #include "telnets.h"
#endif
#ifndef __HAIKU__
 #include "modem.h"
#endif
#ifdef __unix__
 #include "conn_pty.h"
#endif
#ifdef _WIN32
 #include "conn_conpty.h"
#endif
#include "conn_telnet.h"

#ifdef _MSC_VER
#pragma warning(disable : 4244 4267 4018)
#endif

struct conn_api    conn_api;
char              *conn_types_enum[] = {
	"Unknown", "RLogin", "RLoginReversed", "Telnet", "Raw", "SSH", "SSHNA", "Modem", "Serial", "NoRTS", "Shell",
	"MBBSGhost", "TelnetS", NULL
};
char              *conn_types[] = {
	"Unknown", "RLogin", "RLogin Reversed", "Telnet", "Raw", "SSH", "SSH (no auth)", "Modem", "Serial",
	"3-wire (No RTS)", "Shell", "MBBS GHost", "TelnetS", NULL
};
short unsigned int conn_ports[] = {0, 513, 513, 23, 0, 22, 22, 0, 0, 0, 0, 65535, 992, 0};

struct conn_buffer conn_inbuf;
struct conn_buffer conn_outbuf;

/* Buffer functions */
struct conn_buffer *

create_conn_buf(struct conn_buffer *buf, size_t size)
{
	printf("[create_conn_buf] Allocating buffer size=%zu\n", size);
	buf->buf = (unsigned char *)malloc(size);
	if (buf->buf == NULL) {
		printf("[create_conn_buf] malloc failed!\n");
		return NULL;
	}
	buf->bufsize = size;
	buf->buftop = 0;
	buf->bufbot = 0;
	buf->isempty = 1;
	printf("[create_conn_buf] Initializing mutex...\n");
	if (pthread_mutex_init(&(buf->mutex), NULL)) {
		printf("[create_conn_buf] pthread_mutex_init failed!\n");
		FREE_AND_NULL(buf->buf);
		return NULL;
	}
	printf("[create_conn_buf] Initializing in_sem...\n");
	int sem_result = sem_init(&(buf->in_sem), 0, 0);
	printf("[create_conn_buf] sem_init returned %d, errno=%d\n", sem_result, errno);
	if (sem_result) {
		printf("[create_conn_buf] sem_init(in_sem) failed! errno=%d (%s)\n", errno, strerror(errno));
		FREE_AND_NULL(buf->buf);
		pthread_mutex_destroy(&(buf->mutex));
		return NULL;
	}
	printf("[create_conn_buf] Initializing out_sem...\n");
	if (sem_init(&(buf->out_sem), 0, 0)) {
		printf("[create_conn_buf] sem_init(out_sem) failed!\n");
		FREE_AND_NULL(buf->buf);
		pthread_mutex_destroy(&(buf->mutex));
		sem_destroy(&(buf->in_sem));
		return NULL;
	}
	printf("[create_conn_buf] Success!\n");
	return buf;
}

void
destroy_conn_buf(struct conn_buffer *buf)
{
	if (buf->buf != NULL) {
		FREE_AND_NULL(buf->buf);
		while (pthread_mutex_destroy(&(buf->mutex)))
			;
		while (sem_destroy(&(buf->in_sem)))
			;
		while (sem_destroy(&(buf->out_sem)))
			;
	}
}

/*
 * The mutex should always be locked by the caller
 * for the rest of the buffer functions
 */
size_t
conn_buf_bytes(struct conn_buffer *buf)
{
	if (buf->isempty)
		return 0;

	if (buf->buftop > buf->bufbot)
		return buf->buftop - buf->bufbot;
	return buf->bufsize - buf->bufbot + buf->buftop;
}

size_t
conn_buf_free(struct conn_buffer *buf)
{
	return buf->bufsize - conn_buf_bytes(buf);
}

/*
 * Copies up to outlen bytes from the buffer into outbuf,
 * leaving them in the buffer.  Returns the number of bytes
 * copied out of the buffer
 */
size_t
conn_buf_peek(struct conn_buffer *buf, void *voutbuf, size_t outlen)
{
	unsigned char *outbuf = (unsigned char *)voutbuf;
	size_t         copy_bytes;
	size_t         chunk;

	copy_bytes = conn_buf_bytes(buf);
	if (copy_bytes > outlen)
		copy_bytes = outlen;
	chunk = buf->bufsize - buf->bufbot;
	if (chunk > copy_bytes)
		chunk = copy_bytes;

	if (chunk)
		memcpy(outbuf, buf->buf + buf->bufbot, chunk);
	if (chunk < copy_bytes)
		memcpy(outbuf + chunk, buf->buf, copy_bytes - chunk);

	return copy_bytes;
}

/*
 * Copies up to outlen bytes from the buffer into outbuf,
 * removing them from the buffer.  Returns the number of
 * bytes removed from the buffer.
 */
size_t
conn_buf_get(struct conn_buffer *buf, void *voutbuf, size_t outlen)
{
	unsigned char *outbuf = (unsigned char *)voutbuf;
	size_t         ret;
	size_t         atstart;

	atstart = conn_buf_bytes(buf);
	ret = conn_buf_peek(buf, outbuf, outlen);
	if (ret) {
		buf->bufbot += ret;
		if (buf->bufbot >= buf->bufsize)
			buf->bufbot -= buf->bufsize;
		if (ret == atstart)
			buf->isempty = 1;
		sem_post(&(buf->out_sem));
	}
	return ret;
}

/*
 * Places up to outlen bytes from outbuf into the buffer
 * returns the number of bytes written into the buffer
 */
size_t
conn_buf_put(struct conn_buffer *buf, const void *voutbuf, size_t outlen)
{
	const unsigned char *outbuf = (unsigned char *)voutbuf;
	size_t               write_bytes;
	size_t               chunk;

	write_bytes = conn_buf_free(buf);
	if (write_bytes > outlen)
		write_bytes = outlen;
	if (write_bytes) {
		chunk = buf->bufsize - buf->buftop;
		if (chunk > write_bytes)
			chunk = write_bytes;
		if (chunk)
			memcpy(buf->buf + buf->buftop, outbuf, chunk);
		if (chunk < write_bytes)
			memcpy(buf->buf, outbuf + chunk, write_bytes - chunk);
		buf->buftop += write_bytes;
		if (buf->buftop >= buf->bufsize)
			buf->buftop -= buf->bufsize;
		buf->isempty = 0;
		sem_post(&(buf->in_sem));
	}
	return write_bytes;
}

/*
 * Waits up to timeout milliseconds for bcount bytes to be available/free
 * in the buffer.
 */
size_t
conn_buf_wait_cond(struct conn_buffer *buf, size_t bcount, unsigned long timeout, int do_free)
{
	long double   now;
	long double   end;
	size_t        found;
	unsigned long timeleft;
	int           retnow = 0;
	sem_t        *sem;

	size_t        (*cond)(struct conn_buffer *buf);

	if (do_free) {
		sem = &(buf->out_sem);
		cond = conn_buf_free;
	}
	else {
		sem = &(buf->in_sem);
		cond = conn_buf_bytes;
	}

	found = cond(buf);
	if (found > bcount)
		found = bcount;

	if ((found == bcount) || (timeout == 0))
		return found;

	assert_pthread_mutex_unlock(&(buf->mutex));

	end = timeout;
	end /= 1000;
	now = xp_timer();
	end += now;

	for (;;) {
		now = xp_timer();
		if (end <= now) {
			timeleft = 0;
		}
		else {
			timeleft = (end - now) * 1000;
			if ((timeleft < 1) || (timeleft > timeout))
				timeleft = 1;
		}
		if (sem_trywait_block(sem, timeleft))
			retnow = 1;
		assert_pthread_mutex_lock(&(buf->mutex)); /* term.c data_waiting() blocks here, seemingly forever */
		found = cond(buf);
		if (found > bcount)
			found = bcount;

		if ((found == bcount) || retnow)
			return found;

		assert_pthread_mutex_unlock(&(buf->mutex));
	}
}

/*
 * Connection functions
 */
bool
conn_connected(void)
{
	if ((conn_api.input_thread_running == 1) && (conn_api.output_thread_running == 1))
		return true;
	return false;
}

int
conn_recv_upto(void *vbuffer, size_t buflen, unsigned timeout)
{
	char  *buffer = (char *)vbuffer;
	size_t found = 0;
	size_t obuflen;
	void  *expanded;
	size_t max_rx = buflen;

	if (conn_api.rx_parse_cb != NULL) {
		if (max_rx > 1)
			max_rx /= 2;
	}
	assert_pthread_mutex_lock(&(conn_inbuf.mutex));
	if (conn_buf_wait_bytes(&conn_inbuf, 1, timeout))
		found = conn_buf_get(&conn_inbuf, buffer, max_rx);
	assert_pthread_mutex_unlock(&(conn_inbuf.mutex));

	if (found) {
		if (conn_api.rx_parse_cb != NULL) {
			expanded = conn_api.rx_parse_cb(buffer, found, &obuflen);
			memcpy(vbuffer, expanded, obuflen);
			free(expanded);
			found = obuflen;
		}
		else {
			expanded = buffer;
			obuflen = buflen;
		}
	}

	return found;
}

int
conn_send_raw(const void *vbuffer, size_t buflen, unsigned int timeout)
{
	const char *buffer = vbuffer;
	size_t      found;

	assert_pthread_mutex_lock(&(conn_outbuf.mutex));
	found = conn_buf_wait_free(&conn_outbuf, buflen, timeout);
	if (found)
		found = conn_buf_put(&conn_outbuf, buffer, found);
	assert_pthread_mutex_unlock(&(conn_outbuf.mutex));
	return found;
}

int
conn_send(const void *vbuffer, size_t buflen, unsigned int timeout)
{
	const char *buffer = vbuffer;
	size_t      found;
	size_t      obuflen;
	void       *expanded;

	if (conn_api.tx_parse_cb != NULL) {
		expanded = conn_api.tx_parse_cb(buffer, buflen, &obuflen);
	}
	else {
		expanded = (void *)buffer;
		obuflen = buflen;
	}

	assert_pthread_mutex_lock(&(conn_outbuf.mutex));
	found = conn_buf_wait_free(&conn_outbuf, obuflen, timeout);
	if (found)
		found = conn_buf_put(&conn_outbuf, expanded, found);
	assert_pthread_mutex_unlock(&(conn_outbuf.mutex));

	if (conn_api.tx_parse_cb != NULL)
		free(expanded);

	return found;
}

bool
conn_connect(struct bbslist *bbs)
{
	char str[64];

	memset(&conn_api, 0, sizeof(conn_api));

	conn_api.nostatus = bbs->nostatus;
	conn_api.emulation = get_emulation(bbs);
	switch (bbs->conn_type) {
		case CONN_TYPE_RLOGIN:
		case CONN_TYPE_RLOGIN_REVERSED:
			conn_api.connect = rlogin_connect;
			conn_api.close = rlogin_close;
			break;
		case CONN_TYPE_TELNET:
			conn_api.connect = telnet_connect;
			conn_api.close = telnet_close;
			conn_api.binary_mode_on = telnet_binary_mode_on;
			conn_api.binary_mode_off = telnet_binary_mode_off;
			break;
		case CONN_TYPE_RAW:
		case CONN_TYPE_MBBS_GHOST:
			conn_api.connect = raw_connect;
			conn_api.close = raw_close;
			break;
#ifndef WITHOUT_CRYPTLIB
		case CONN_TYPE_TELNETS:
			conn_api.connect = telnets_connect;
			conn_api.close = telnets_close;
			conn_api.binary_mode_on = telnet_binary_mode_on;
			conn_api.binary_mode_off = telnet_binary_mode_off;
			break;
		case CONN_TYPE_SSHNA:
		case CONN_TYPE_SSH:
			conn_api.connect = ssh_connect;
			conn_api.close = ssh_close;
			break;
#endif
#ifndef __HAIKU__
		case CONN_TYPE_SERIAL:
		case CONN_TYPE_SERIAL_NORTS:
			conn_api.connect = modem_connect;
			conn_api.close = serial_close;
			break;
		case CONN_TYPE_MODEM:
			conn_api.connect = modem_connect;
			conn_api.close = modem_close;
			break;
#endif
#ifdef __unix__
		case CONN_TYPE_SHELL:
			conn_api.connect = pty_connect;
			conn_api.close = pty_close;
			break;
#endif
#ifdef HAS_CONPTY
		case CONN_TYPE_SHELL:
			conn_api.connect = conpty_connect;
			conn_api.close = conpty_close;
			break;
#endif
		default:
			sprintf(str, "%s connections not supported.", conn_types[bbs->conn_type]);
			uifcmsg(str, "`Connection type not supported`\n\n"
			    "The connection type of this entry is not supported by this build.\n"
			    "Either the protocol was disabled at compile time, or is\n"
			    "unsupported on this plattform.");
			conn_api.terminate = true;
	}
	if (conn_api.connect) {
		printf("[conn_connect] Calling protocol-specific connect()\n");
		int connect_result = conn_api.connect(bbs);
		printf("[conn_connect] Protocol connect returned %d\n", connect_result);
		if (connect_result) {
			printf("[conn_connect] Connect failed, setting terminate=true\n");
			conn_api.terminate = true;
			while (conn_api.input_thread_running == 1 || conn_api.output_thread_running == 1)
				SLEEP(1);
		}
		else {
			printf("[conn_connect] Connect succeeded, waiting for threads to start...\n");
			int wait_loops = 0;
			while ((!conn_api.terminate)
			    && (conn_api.input_thread_running == 0 || conn_api.output_thread_running == 0)) {
				SLEEP(1);
				wait_loops++;
				if (wait_loops % 100 == 0) {
					printf("[conn_connect] Still waiting: terminate=%d, input_running=%d, output_running=%d\n",
					       conn_api.terminate, conn_api.input_thread_running, conn_api.output_thread_running);
				}
			}
			printf("[conn_connect] Done waiting: terminate=%d, input_running=%d, output_running=%d\n",
			       conn_api.terminate, conn_api.input_thread_running, conn_api.output_thread_running);
		}
	}
	printf("[conn_connect] Returning terminate=%d\n", conn_api.terminate);
	return conn_api.terminate;
}

size_t
conn_data_waiting(void)
{
	size_t found;

	assert_pthread_mutex_lock(&(conn_inbuf.mutex));
	found = conn_buf_bytes(&conn_inbuf);
	assert_pthread_mutex_unlock(&(conn_inbuf.mutex));
	return found;
}

int
conn_close(void)
{
	if (conn_api.close)
		return conn_api.close();
	return 0;
}

enum failure_reason {
	FAILURE_WHAT_FAILURE
	,
	FAILURE_RESOLVE
	,
	FAILURE_CANT_CREATE
	,
	FAILURE_CONNECT_ERROR
	,
	FAILURE_ABORTED
	,
	FAILURE_DISCONNECTED
};

SOCKET
conn_socket_connect(struct bbslist *bbs, bool can_cancel)
{
	SOCKET           sock = INVALID_SOCKET;
#ifdef _WIN32
	u_long           nonblock;
#else
	int              nonblock;
#endif
	int              failcode = FAILURE_WHAT_FAILURE;
	struct addrinfo  hints;
	struct addrinfo *res = NULL;
	struct addrinfo *cur;
	char             portnum[6];
	char             str[LIST_ADDR_MAX + 40];

	printf("[conn_socket_connect] Starting connection to %s:%d\n", bbs->addr, bbs->port);
	if (!bbs->hidepopups)
		uifc.pop("Looking up host");
	memset(&hints, 0, sizeof(hints));
	hints.ai_flags = PF_UNSPEC;
	switch (bbs->address_family) {
		case ADDRESS_FAMILY_INET:
			hints.ai_family = PF_INET;
			break;
		case ADDRESS_FAMILY_INET6:
			hints.ai_family = PF_INET6;
			break;
		case ADDRESS_FAMILY_UNSPEC:
		default:
			hints.ai_family = PF_UNSPEC;
			break;
	}
	hints.ai_socktype = SOCK_STREAM;
	hints.ai_protocol = IPPROTO_TCP;
	hints.ai_flags = AI_NUMERICSERV;
#ifdef AI_ADDRCONFIG
	hints.ai_flags |= AI_ADDRCONFIG;
#endif
	sprintf(portnum, "%hu", bbs->port);
	printf("[conn_socket_connect] Calling getaddrinfo for %s:%s\n", bbs->addr, portnum);
	int gai_result = getaddrinfo(bbs->addr, portnum, &hints, &res);
	if (gai_result != 0) {
		printf("[conn_socket_connect] getaddrinfo failed: %d (%s)\n", gai_result, gai_strerror(gai_result));
		failcode = FAILURE_RESOLVE;
		res = NULL;
	} else {
		printf("[conn_socket_connect] getaddrinfo succeeded, res=%p\n", (void*)res);
	}
	if (!bbs->hidepopups) {
		uifc.pop(NULL);
		uifc.pop("Connecting...");
	}

	if (can_cancel) {
		/* Drain the input buffer to avoid accidental cancel */
		while (kbhit())
			getch();
	}

	printf("[conn_socket_connect] Entering connection loop\n");
	for (cur = res; cur && sock == INVALID_SOCKET && failcode == FAILURE_WHAT_FAILURE; cur = cur->ai_next) {
		printf("[conn_socket_connect] Trying address family=%d, socktype=%d, protocol=%d\n",
		       cur->ai_family, cur->ai_socktype, cur->ai_protocol);
		if (sock == INVALID_SOCKET) {
			sock = socket(cur->ai_family, cur->ai_socktype, cur->ai_protocol);
			if (sock == INVALID_SOCKET) {
				printf("[conn_socket_connect] socket() failed: %d (%s)\n", errno, strerror(errno));
				failcode = FAILURE_CANT_CREATE;
				break;
			}
			printf("[conn_socket_connect] socket created: %d\n", sock);

                        /* Set to non-blocking for the connect */
			nonblock = -1;
			ioctlsocket(sock, FIONBIO, &nonblock);
		}

		printf("[conn_socket_connect] Calling connect()\n");
		if (connect(sock, cur->ai_addr, cur->ai_addrlen)) {
			int tries = 0;
			int err = ERROR_VALUE;
			printf("[conn_socket_connect] connect() returned non-zero, ERROR_VALUE=%d\n", err);
			switch (err) {
				case EINPROGRESS:
				case EINTR:
				case EAGAIN:
#if (EAGAIN != EWOULDBLOCK)
				case EWOULDBLOCK:
#endif
					printf("[conn_socket_connect] Waiting for connection (EINPROGRESS/etc)...\n");
					for (; sock != INVALID_SOCKET;) {
						if (socket_writable(sock, 1000)) {
							tries++;
							printf("[conn_socket_connect] socket writable, tries=%d, can_cancel=%d\n", tries, can_cancel);
							if (tries >= 5 && !can_cancel)  {
								printf("[conn_socket_connect] Too many tries, closing socket\n");
								closesocket(sock);
								sock = INVALID_SOCKET;
								continue;
							}
							else if (socket_recvdone(sock, 0)) {
								printf("[conn_socket_connect] socket_recvdone returned true, closing\n");
								closesocket(sock);
								sock = INVALID_SOCKET;
								continue;
							}
							else {
								printf("[conn_socket_connect] Connection established!\n");
								goto connected;
							}
						}
						else {
							if (can_cancel) {
								if (kbhit()) {
									printf("[conn_socket_connect] User cancelled via kbhit\n");
									failcode = FAILURE_ABORTED;
									closesocket(sock);
									sock = INVALID_SOCKET;
								}
							}
						}
					}

connected:
					break;
				default:
					printf("[conn_socket_connect] connect() failed with error %d\n", err);
					closesocket(sock);
					sock = INVALID_SOCKET;
					continue;
			}
		}
	}
	if (sock != INVALID_SOCKET) {
		freeaddrinfo(res);
		res = NULL;
		nonblock = 0;
		ioctlsocket(sock, FIONBIO, &nonblock);
		if (!socket_recvdone(sock, 0)) {
			int keepalives = true;
			if (setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, (void *)&keepalives, sizeof(keepalives)))
				fprintf(stderr, "%s:%d: Error %d calling setsockopt()\n", __FILE__, __LINE__, errno);

			if (!bbs->hidepopups)
				uifc.pop(NULL);
			return sock;
		}
		failcode = FAILURE_DISCONNECTED;
	}
	if (failcode == FAILURE_WHAT_FAILURE)
		failcode = FAILURE_CONNECT_ERROR;

	if (res)
		freeaddrinfo(res);
	if (!bbs->hidepopups)
		uifc.pop(NULL);
	conn_api.terminate = true;
	if (!bbs->hidepopups) {
		switch (failcode) {
			case FAILURE_RESOLVE:
				sprintf(str, "Cannot resolve %s!", bbs->addr);
				uifcmsg(str, "`Cannot Resolve Host`\n\n"
				    "The system is unable to resolve the hostname... double check the spelling.\n"
				    "If it's not an issue with your DNS settings, the issue is probobly\n"
				    "with the DNS settings of the system you are trying to contact.");
				break;
			case FAILURE_CANT_CREATE:
				sprintf(str, "Cannot create socket (%d)!", ERROR_VALUE);
				uifcmsg(str,
				    "`Unable to create socket`\n\n"
				    "Your system is either dangerously low on resources, or there\n"
				    "is a problem with your TCP/IP stack.");
				break;
			case FAILURE_CONNECT_ERROR:
				sprintf(str, "Connect error (%d)!", ERROR_VALUE);
				uifcmsg(str,
				    "`The connect call returned an error`\n\n"
				    "The call to connect() returned an unexpected error code.");
				break;
			case FAILURE_ABORTED:
				uifcmsg("Connection Aborted.", "`Connection Aborted`\n\n"
				    "Connection to the remote system aborted by keystroke.");
				break;
			case FAILURE_DISCONNECTED:
				sprintf(str, "Connect error (%d)!", ERROR_VALUE);
				uifcmsg(str,
				    "`SyncTERM failed to connect`\n\n"
				    "After connect() succeeded, the socket was in a disconnected state.");
				break;
		}
	}
	conn_close();
	if (sock != INVALID_SOCKET)
		closesocket(sock);
	return INVALID_SOCKET;
}

void
conn_binary_mode_on(void)
{
	if (conn_api.binary_mode_on)
		conn_api.binary_mode_on();
	conn_api.binary_mode = true;
}

void
conn_binary_mode_off(void)
{
	if (conn_api.binary_mode_off)
		conn_api.binary_mode_off();
	conn_api.binary_mode = false;
}
