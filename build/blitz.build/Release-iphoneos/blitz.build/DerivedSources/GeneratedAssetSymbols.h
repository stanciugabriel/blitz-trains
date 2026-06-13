#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The "astra" asset catalog image resource.
static NSString * const ACImageNameAstra AC_SWIFT_PRIVATE = @"astra";

/// The "cfr" asset catalog image resource.
static NSString * const ACImageNameCfr AC_SWIFT_PRIVATE = @"cfr";

/// The "interregional" asset catalog image resource.
static NSString * const ACImageNameInterregional AC_SWIFT_PRIVATE = @"interregional";

/// The "regio" asset catalog image resource.
static NSString * const ACImageNameRegio AC_SWIFT_PRIVATE = @"regio";

/// The "softrans" asset catalog image resource.
static NSString * const ACImageNameSoftrans AC_SWIFT_PRIVATE = @"softrans";

/// The "tfc" asset catalog image resource.
static NSString * const ACImageNameTfc AC_SWIFT_PRIVATE = @"tfc";

/// The "train" asset catalog image resource.
static NSString * const ACImageNameTrain AC_SWIFT_PRIVATE = @"train";

#undef AC_SWIFT_PRIVATE
