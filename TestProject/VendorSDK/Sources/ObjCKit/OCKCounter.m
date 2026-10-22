#import "OCKCounter.h"

@implementation OCKCounter

- (NSInteger)increment {
    NSInteger next = _count + 1;                    // BREAKPOINT ObjCKit.increment
    _count = next;
    return next;
}

@end
