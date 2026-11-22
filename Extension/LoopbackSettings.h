#import <NetworkExtension/NetworkExtension.h>
#import <Network/Network.h>

NS_ASSUME_NONNULL_BEGIN

NEFilterSettings *RiftAllowAllFilterSettings(void);
NSDictionary<NSString *, id> * _Nullable RiftCopyLocalEndpointParts(NEFilterSocketFlow *flow);
NSDictionary<NSString *, id> * _Nullable RiftCopyRemoteEndpointParts(NEFilterSocketFlow *flow);
uint32_t RiftAuditTokenEUID(NSData * _Nullable token);
/// The process ID in an audit token, or 0 when there isn't one.
int32_t RiftAuditTokenPID(NSData * _Nullable token);
/// The executable of the exact process an audit token names. Nil once that
/// process has exited, so a reused process ID can't supply another path.
NSString * _Nullable RiftCopyAuditTokenExecutablePath(NSData * _Nullable token);

NS_ASSUME_NONNULL_END
