#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <linux/if_tun.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef IPPROTO_SCTP
#define IPPROTO_SCTP 132
#endif

#define BUFFER_SIZE 65535
#define COMMAND_ERROR 2

static void fail(const char *operation)
{
    perror(operation);
    exit(EXIT_FAILURE);
}

static int parse_port(const char *value)
{
    char *end = NULL;
    long parsed = strtol(value, &end, 10);
    if (value[0] == '\0' || end == NULL || *end != '\0' ||
        parsed < 1 || parsed > 65535) {
        fprintf(stderr, "invalid port: %s\n", value);
        exit(COMMAND_ERROR);
    }
    return (int)parsed;
}

static void port_text(int port, char output[6])
{
    if (snprintf(output, 6, "%d", port) < 1) {
        fail("snprintf");
    }
}

static struct addrinfo *resolve_address(
    const char *host, int port, int socket_type, int protocol, bool passive)
{
    struct addrinfo hints;
    struct addrinfo *result = NULL;
    char service[6];
    int status;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = socket_type;
    hints.ai_protocol = protocol;
    hints.ai_flags = passive ? AI_PASSIVE : 0;
    port_text(port, service);
    status = getaddrinfo(passive ? NULL : host, service, &hints, &result);
    if (status != 0) {
        fprintf(stderr, "getaddrinfo: %s\n", gai_strerror(status));
        exit(EXIT_FAILURE);
    }
    return result;
}

static int open_server_socket(int socket_type, int protocol, int port)
{
    struct addrinfo *addresses = resolve_address(
        NULL, port, socket_type, protocol, true);
    int descriptor = -1;
    int enabled = 1;

    for (struct addrinfo *item = addresses; item != NULL;
         item = item->ai_next) {
        descriptor = socket(item->ai_family, item->ai_socktype,
                            item->ai_protocol);
        if (descriptor < 0) {
            continue;
        }
        (void)setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR,
                         &enabled, sizeof(enabled));
        if (bind(descriptor, item->ai_addr, item->ai_addrlen) == 0) {
            break;
        }
        close(descriptor);
        descriptor = -1;
    }
    freeaddrinfo(addresses);
    if (descriptor < 0) {
        fail("bind");
    }
    return descriptor;
}

static int open_client_socket(
    const char *host, int socket_type, int protocol, int port)
{
    struct addrinfo *addresses = resolve_address(
        host, port, socket_type, protocol, false);
    int descriptor = -1;

    for (struct addrinfo *item = addresses; item != NULL;
         item = item->ai_next) {
        descriptor = socket(item->ai_family, item->ai_socktype,
                            item->ai_protocol);
        if (descriptor < 0) {
            continue;
        }
        if (connect(descriptor, item->ai_addr, item->ai_addrlen) == 0) {
            break;
        }
        close(descriptor);
        descriptor = -1;
    }
    freeaddrinfo(addresses);
    if (descriptor < 0) {
        fail("connect");
    }
    return descriptor;
}

static void send_all(int descriptor, const char *data, size_t length)
{
    size_t sent = 0;
    while (sent < length) {
        ssize_t current = send(descriptor, data + sent, length - sent, 0);
        if (current < 0) {
            fail("send");
        }
        sent += (size_t)current;
    }
}

static void stream_server(int protocol, int port, const char *label)
{
    int server = open_server_socket(SOCK_STREAM, protocol, port);
    if (listen(server, 16) != 0) {
        fail("listen");
    }
    printf("listener=%s port=%d state=ready\n", label, port);
    fflush(stdout);

    for (;;) {
        char buffer[BUFFER_SIZE];
        int client = accept(server, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) {
                continue;
            }
            fail("accept");
        }
        ssize_t received = recv(client, buffer, sizeof(buffer) - 1, 0);
        if (received > 0) {
            char response[BUFFER_SIZE];
            buffer[received] = '\0';
            int response_length = snprintf(response, sizeof(response),
                                           "ack:%s", buffer);
            if (response_length < 0 ||
                (size_t)response_length >= sizeof(response)) {
                fprintf(stderr, "stream payload is too long\n");
                close(client);
                continue;
            }
            send_all(client, response, (size_t)response_length);
            printf("received=%s transport=%s\n", buffer, label);
            fflush(stdout);
        }
        close(client);
    }
}

static void stream_client(
    int protocol, const char *host, int port, const char *payload,
    const char *label)
{
    char response[BUFFER_SIZE];
    char expected[BUFFER_SIZE];
    int descriptor = open_client_socket(host, SOCK_STREAM, protocol, port);
    size_t payload_length = strlen(payload);

    if (payload_length + 5 > sizeof(expected)) {
        fprintf(stderr, "payload is too long\n");
        exit(COMMAND_ERROR);
    }
    send_all(descriptor, payload, payload_length);
    ssize_t received = recv(descriptor, response, sizeof(response) - 1, 0);
    if (received < 0) {
        fail("recv");
    }
    response[received] = '\0';
    (void)snprintf(expected, sizeof(expected), "ack:%s", payload);
    if (strcmp(response, expected) != 0) {
        fprintf(stderr, "unexpected response: %s\n", response);
        exit(EXIT_FAILURE);
    }
    printf("transport=%s destination=%s:%d response=%s result=pass\n",
           label, host, port, response);
    close(descriptor);
}

static void udp_server(int port)
{
    int descriptor = open_server_socket(SOCK_DGRAM, IPPROTO_UDP, port);
    printf("listener=udp port=%d state=ready\n", port);
    fflush(stdout);

    for (;;) {
        char buffer[BUFFER_SIZE];
        char response[BUFFER_SIZE];
        struct sockaddr_storage peer;
        socklen_t peer_length = sizeof(peer);
        ssize_t received = recvfrom(descriptor, buffer, sizeof(buffer) - 1, 0,
                                    (struct sockaddr *)&peer, &peer_length);
        if (received < 0) {
            if (errno == EINTR) {
                continue;
            }
            fail("recvfrom");
        }
        buffer[received] = '\0';
        int response_length = snprintf(response, sizeof(response),
                                       "ack:%s", buffer);
        if (response_length < 0 || (size_t)response_length >= sizeof(response)) {
            fprintf(stderr, "UDP payload is too long\n");
            continue;
        }
        if (sendto(descriptor, response, (size_t)response_length, 0,
                   (struct sockaddr *)&peer, peer_length) < 0) {
            fail("sendto");
        }
        printf("received=%s transport=udp port=%d\n", buffer, port);
        fflush(stdout);
    }
}

static void udp_client(const char *host, int port, const char *payload)
{
    char response[BUFFER_SIZE];
    char expected[BUFFER_SIZE];
    int descriptor = open_client_socket(host, SOCK_DGRAM, IPPROTO_UDP, port);
    struct timeval timeout = {.tv_sec = 5, .tv_usec = 0};
    (void)setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO,
                     &timeout, sizeof(timeout));
    size_t payload_length = strlen(payload);

    if (send(descriptor, payload, payload_length, 0) < 0) {
        fail("send");
    }
    ssize_t received = recv(descriptor, response, sizeof(response) - 1, 0);
    if (received < 0) {
        fail("recv");
    }
    response[received] = '\0';
    (void)snprintf(expected, sizeof(expected), "ack:%s", payload);
    if (strcmp(response, expected) != 0) {
        fprintf(stderr, "unexpected response: %s\n", response);
        exit(EXIT_FAILURE);
    }
    printf("transport=udp destination=%s:%d response=%s result=pass\n",
           host, port, response);
    close(descriptor);
}

static int run_program(char *const arguments[])
{
    pid_t child = fork();
    if (child < 0) {
        fail("fork");
    }
    if (child == 0) {
        execvp(arguments[0], arguments);
        perror("execvp");
        _exit(127);
    }
    int status = 0;
    if (waitpid(child, &status, 0) < 0) {
        fail("waitpid");
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "command failed: %s\n", arguments[0]);
        exit(EXIT_FAILURE);
    }
    return status;
}

static int create_tun(const char *interface_name, const char *address)
{
    struct ifreq request;
    int descriptor = open("/dev/net/tun", O_RDWR | O_CLOEXEC);
    if (descriptor < 0) {
        fail("open /dev/net/tun");
    }
    memset(&request, 0, sizeof(request));
    request.ifr_flags = IFF_TUN | IFF_NO_PI;
    if (strlen(interface_name) >= IFNAMSIZ) {
        fprintf(stderr, "interface name is too long\n");
        exit(COMMAND_ERROR);
    }
    (void)strncpy(request.ifr_name, interface_name, IFNAMSIZ - 1);
    if (ioctl(descriptor, TUNSETIFF, &request) < 0) {
        fail("ioctl TUNSETIFF");
    }

    char *address_arguments[] = {
        "ip", "address", "replace", (char *)address,
        "dev", (char *)interface_name, NULL};
    char *link_arguments[] = {
        "ip", "link", "set", "dev", (char *)interface_name,
        "up", NULL};
    run_program(address_arguments);
    run_program(link_arguments);
    printf("tun_interface=%s address=%s state=up\n",
           interface_name, address);
    fflush(stdout);
    return descriptor;
}

static void tun_hold(const char *interface_name, const char *address,
                     bool remain)
{
    int descriptor = create_tun(interface_name, address);
    printf("tun_access=pass\n");
    fflush(stdout);
    if (remain) {
        for (;;) {
            pause();
        }
    }
    close(descriptor);
}

static void tunnel_relay(bool server_mode, const char *interface_name,
                         const char *address, const char *host, int port)
{
    int tun = create_tun(interface_name, address);
    int udp;
    struct sockaddr_storage peer;
    socklen_t peer_length = 0;
    bool peer_known = false;

    if (server_mode) {
        udp = open_server_socket(SOCK_DGRAM, IPPROTO_UDP, port);
    } else {
        udp = open_client_socket(host, SOCK_DGRAM, IPPROTO_UDP, port);
        static const char hello[] = "CN5G-HELLO";
        if (send(udp, hello, sizeof(hello) - 1, 0) < 0) {
            fail("send tunnel hello");
        }
        peer_known = true;
    }
    printf("tunnel_mode=%s udp_port=%d state=ready\n",
           server_mode ? "server" : "client", port);
    fflush(stdout);

    for (;;) {
        uint8_t buffer[BUFFER_SIZE];
        struct pollfd descriptors[2] = {
            {.fd = tun, .events = POLLIN},
            {.fd = udp, .events = POLLIN},
        };
        if (poll(descriptors, 2, -1) < 0) {
            if (errno == EINTR) {
                continue;
            }
            fail("poll");
        }
        if ((descriptors[1].revents & POLLIN) != 0) {
            ssize_t received;
            if (server_mode) {
                peer_length = sizeof(peer);
                received = recvfrom(udp, buffer, sizeof(buffer), 0,
                                    (struct sockaddr *)&peer, &peer_length);
            } else {
                received = recv(udp, buffer, sizeof(buffer), 0);
            }
            if (received < 0) {
                fail("recv tunnel");
            }
            if (server_mode) {
                peer_known = true;
            }
            if ((size_t)received == strlen("CN5G-HELLO") &&
                memcmp(buffer, "CN5G-HELLO", strlen("CN5G-HELLO")) == 0) {
                continue;
            }
            if (write(tun, buffer, (size_t)received) != received) {
                fail("write tun");
            }
        }
        if ((descriptors[0].revents & POLLIN) != 0) {
            ssize_t received = read(tun, buffer, sizeof(buffer));
            if (received < 0) {
                fail("read tun");
            }
            if (!peer_known) {
                continue;
            }
            ssize_t sent;
            if (server_mode) {
                sent = sendto(udp, buffer, (size_t)received, 0,
                              (struct sockaddr *)&peer, peer_length);
            } else {
                sent = send(udp, buffer, (size_t)received, 0);
            }
            if (sent != received) {
                fail("send tunnel packet");
            }
        }
    }
}

static int protocol_number(const char *name)
{
    if (strcmp(name, "tcp") == 0) {
        return IPPROTO_TCP;
    }
    if (strcmp(name, "udp") == 0) {
        return IPPROTO_UDP;
    }
    if (strcmp(name, "sctp") == 0) {
        return IPPROTO_SCTP;
    }
    fprintf(stderr, "unsupported capture protocol: %s\n", name);
    exit(COMMAND_ERROR);
}

static void packet_capture(const char *interface_name, const char *protocol_name,
                           int port, int required_count)
{
    int wanted_protocol = protocol_number(protocol_name);
    int descriptor = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (descriptor < 0) {
        fail("socket AF_PACKET");
    }
    if (strcmp(interface_name, "any") != 0) {
        struct sockaddr_ll address;
        memset(&address, 0, sizeof(address));
        address.sll_family = AF_PACKET;
        address.sll_protocol = htons(ETH_P_ALL);
        address.sll_ifindex = (int)if_nametoindex(interface_name);
        if (address.sll_ifindex == 0) {
            fail("if_nametoindex");
        }
        if (bind(descriptor, (struct sockaddr *)&address, sizeof(address)) < 0) {
            fail("bind AF_PACKET");
        }
    }
    printf("capture_interface=%s protocol=%s port=%d state=ready\n",
           interface_name, protocol_name, port);
    fflush(stdout);

    int observed = 0;
    while (observed < required_count) {
        uint8_t buffer[BUFFER_SIZE];
        ssize_t length = recv(descriptor, buffer, sizeof(buffer), 0);
        if (length < (ssize_t)(sizeof(struct ethhdr) + sizeof(struct iphdr))) {
            continue;
        }
        struct ethhdr *ethernet = (struct ethhdr *)buffer;
        if (ntohs(ethernet->h_proto) != ETH_P_IP) {
            continue;
        }
        struct iphdr *ip = (struct iphdr *)(buffer + sizeof(struct ethhdr));
        size_t ip_header_length = (size_t)ip->ihl * 4;
        size_t transport_offset = sizeof(struct ethhdr) + ip_header_length;
        if (ip->protocol != wanted_protocol ||
            length < (ssize_t)(transport_offset + 4)) {
            continue;
        }
        uint16_t source_port;
        uint16_t destination_port;
        memcpy(&source_port, buffer + transport_offset, sizeof(source_port));
        memcpy(&destination_port, buffer + transport_offset + 2,
               sizeof(destination_port));
        source_port = ntohs(source_port);
        destination_port = ntohs(destination_port);
        if (source_port != (uint16_t)port &&
            destination_port != (uint16_t)port) {
            continue;
        }
        char source[INET_ADDRSTRLEN];
        char destination[INET_ADDRSTRLEN];
        (void)inet_ntop(AF_INET, &ip->saddr, source, sizeof(source));
        (void)inet_ntop(AF_INET, &ip->daddr, destination, sizeof(destination));
        observed++;
        printf("packet=%d protocol=%s source=%s:%u destination=%s:%u bytes=%zd\n",
               observed, protocol_name, source, source_port,
               destination, destination_port, length);
        fflush(stdout);
    }
    printf("packet_visibility=pass count=%d\n", observed);
    close(descriptor);
}

static void usage(void)
{
    puts("Usage: cn5g-feasibility-probe COMMAND ...\n"
         "  tcp-server PORT\n"
         "  tcp-client HOST PORT PAYLOAD\n"
         "  udp-server PORT\n"
         "  udp-client HOST PORT PAYLOAD\n"
         "  sctp-server PORT\n"
         "  sctp-client HOST PORT PAYLOAD\n"
         "  tun-once IFNAME ADDRESS/PREFIX\n"
         "  tun-hold IFNAME ADDRESS/PREFIX\n"
         "  tunnel-server IFNAME ADDRESS/PREFIX UDP-PORT\n"
         "  tunnel-client IFNAME ADDRESS/PREFIX HOST UDP-PORT\n"
         "  capture IFACE|any tcp|udp|sctp PORT COUNT");
}

int main(int argc, char **argv)
{
    if (argc < 2 || strcmp(argv[1], "help") == 0) {
        usage();
        return argc < 2 ? COMMAND_ERROR : EXIT_SUCCESS;
    }
    if (strcmp(argv[1], "tcp-server") == 0 && argc == 3) {
        stream_server(IPPROTO_TCP, parse_port(argv[2]), "tcp");
    } else if (strcmp(argv[1], "tcp-client") == 0 && argc == 5) {
        stream_client(IPPROTO_TCP, argv[2], parse_port(argv[3]), argv[4], "tcp");
    } else if (strcmp(argv[1], "udp-server") == 0 && argc == 3) {
        udp_server(parse_port(argv[2]));
    } else if (strcmp(argv[1], "udp-client") == 0 && argc == 5) {
        udp_client(argv[2], parse_port(argv[3]), argv[4]);
    } else if (strcmp(argv[1], "sctp-server") == 0 && argc == 3) {
        stream_server(IPPROTO_SCTP, parse_port(argv[2]), "sctp");
    } else if (strcmp(argv[1], "sctp-client") == 0 && argc == 5) {
        stream_client(IPPROTO_SCTP, argv[2], parse_port(argv[3]), argv[4], "sctp");
    } else if (strcmp(argv[1], "tun-once") == 0 && argc == 4) {
        tun_hold(argv[2], argv[3], false);
    } else if (strcmp(argv[1], "tun-hold") == 0 && argc == 4) {
        tun_hold(argv[2], argv[3], true);
    } else if (strcmp(argv[1], "tunnel-server") == 0 && argc == 5) {
        tunnel_relay(true, argv[2], argv[3], NULL, parse_port(argv[4]));
    } else if (strcmp(argv[1], "tunnel-client") == 0 && argc == 6) {
        tunnel_relay(false, argv[2], argv[3], argv[4], parse_port(argv[5]));
    } else if (strcmp(argv[1], "capture") == 0 && argc == 6) {
        int count = atoi(argv[5]);
        if (count < 1 || count > 1000) {
            fprintf(stderr, "capture count must be between 1 and 1000\n");
            return COMMAND_ERROR;
        }
        packet_capture(argv[2], argv[3], parse_port(argv[4]), count);
    } else {
        usage();
        return COMMAND_ERROR;
    }
    return EXIT_SUCCESS;
}
