#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Shipped as an Objective-C static library (`libObjCKit.a`) inside `ObjCKit.xcframework`.
@interface OCKCounter : NSObject
@property (nonatomic, readonly) NSInteger count;
- (NSInteger)increment;
@end

NS_ASSUME_NONNULL_END
