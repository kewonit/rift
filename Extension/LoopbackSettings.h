#import <NetworkExtension/NetworkExtension.h>
#import <Network/Network.h>

NS_ASSUME_NONNULL_BEGIN

NEFilterSettings *AbyssAllowAllFilterSettings(void);
NSDictionary<NSString *, id> * _Nullable AbyssCopyLocalEndpointParts(NEFilterSocketFlow *flow);
NSDictionary<NSString *, id> * _Nullable AbyssCopyRemoteEndpointParts(NEFilterSocketFlow *flow);
uint32_t AbyssAuditTokenEUID(NSData * _Nullable token);

NS_ASSUME_NONNULL_END
