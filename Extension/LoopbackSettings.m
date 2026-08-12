#import "LoopbackSettings.h"
#import <bsm/libbsm.h>

NEFilterSettings *AbyssAllowAllFilterSettings(void) {
    NWHostEndpoint *loopbackV4Endpoint =
        [NWHostEndpoint endpointWithHostname:@"127.0.0.1" port:@"0"];
    NWHostEndpoint *loopbackV6Endpoint =
        [NWHostEndpoint endpointWithHostname:@"::1" port:@"0"];
    NENetworkRule *loopbackV4 =
        [[NENetworkRule alloc] initWithDestinationNetwork:loopbackV4Endpoint
                                                   prefix:8
                                                 protocol:NENetworkRuleProtocolAny];
    NENetworkRule *loopbackV6 =
        [[NENetworkRule alloc] initWithDestinationNetwork:loopbackV6Endpoint
                                                   prefix:128
                                                 protocol:NENetworkRuleProtocolAny];
    NEFilterRule *filterV4 = [[NEFilterRule alloc] initWithNetworkRule:loopbackV4
                                                               action:NEFilterActionFilterData];
    NEFilterRule *filterV6 = [[NEFilterRule alloc] initWithNetworkRule:loopbackV6
                                                               action:NEFilterActionFilterData];
    return [[NEFilterSettings alloc] initWithRules:@[filterV4, filterV6]
                                     defaultAction:NEFilterActionFilterData];
}

static NSDictionary<NSString *, id> *AbyssCopyLegacyEndpointParts(NWEndpoint *endpoint) {
    if (![endpoint isKindOfClass:[NWHostEndpoint class]]) {
        return nil;
    }
    NWHostEndpoint *host = (NWHostEndpoint *)endpoint;
    return @{ @"host": host.hostname, @"port": host.port };
}

static NSDictionary<NSString *, id> *AbyssCopyFlowEndpointParts(nw_endpoint_t endpoint) {
    if (endpoint == nil || nw_endpoint_get_type(endpoint) != nw_endpoint_type_host) {
        return nil;
    }
    const char *host = nw_endpoint_get_hostname(endpoint);
    uint16_t port = nw_endpoint_get_port(endpoint);
    if (host == NULL) {
        return nil;
    }
    return @{ @"host": [NSString stringWithUTF8String:host], @"port": @(port) };
}

NSDictionary<NSString *, id> *AbyssCopyLocalEndpointParts(NEFilterSocketFlow *flow) {
    if (@available(macOS 15.0, *)) {
        return AbyssCopyFlowEndpointParts(flow.localFlowEndpoint);
    }
    return AbyssCopyLegacyEndpointParts(flow.localEndpoint);
}

NSDictionary<NSString *, id> *AbyssCopyRemoteEndpointParts(NEFilterSocketFlow *flow) {
    if (@available(macOS 15.0, *)) {
        return AbyssCopyFlowEndpointParts(flow.remoteFlowEndpoint);
    }
    return AbyssCopyLegacyEndpointParts(flow.remoteEndpoint);
}

uint32_t AbyssAuditTokenEUID(NSData *token) {
    if (token == nil || token.length != sizeof(audit_token_t)) {
        return UINT32_MAX;
    }
    audit_token_t auditToken;
    [token getBytes:&auditToken length:sizeof(auditToken)];
    return audit_token_to_euid(auditToken);
}
