#import "../Extension/LoopbackSettings.m"
#import <arpa/inet.h>

int main(void) {
    @autoreleasepool {
        struct sockaddr_in ipv4 = { .sin_len = sizeof(ipv4), .sin_family = AF_INET, .sin_port = htons(12345) };
        inet_pton(AF_INET, "127.0.0.1", &ipv4.sin_addr);
        struct sockaddr_in6 ipv6 = { .sin6_len = sizeof(ipv6), .sin6_family = AF_INET6, .sin6_port = htons(443) };
        inet_pton(AF_INET6, "::1", &ipv6.sin6_addr);
        NSArray *endpoints = @[
            nw_endpoint_create_host("example.invalid", "8443"),
            nw_endpoint_create_address((const struct sockaddr *)&ipv4),
            nw_endpoint_create_address((const struct sockaddr *)&ipv6)
        ];
        NSArray *hosts = @[@"example.invalid", @"127.0.0.1", @"::1"];
        NSArray *ports = @[@8443, @12345, @443];
        for (NSUInteger i = 0; i < endpoints.count; i++) {
            NSDictionary *parts = RiftCopyFlowEndpointParts(endpoints[i]);
            if (![parts[@"host"] isEqual:hosts[i]] || ![parts[@"port"] isEqual:ports[i]]) {
                fprintf(stderr, "FAIL: endpoint %lu lost its address or port\n", (unsigned long)i);
                return 1;
            }
        }
        if (RiftCopyFlowEndpointParts(nil) != nil) return 1;
        puts("PASS: hostname, IPv4, IPv6, and absent endpoint conversion");
    }
    return 0;
}
