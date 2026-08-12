#import <NetworkExtension/NetworkExtension.h>
#import <Network/Network.h>

NS_ASSUME_NONNULL_BEGIN

NEFilterSettings *RiftAllowAllFilterSettings(void);
NSDictionary<NSString *, id> * _Nullable RiftCopyLocalEndpointParts(NEFilterSocketFlow *flow);
NSDictionary<NSString *, id> * _Nullable RiftCopyRemoteEndpointParts(NEFilterSocketFlow *flow);
uint32_t RiftAuditTokenEUID(NSData * _Nullable token);

NS_ASSUME_NONNULL_END
