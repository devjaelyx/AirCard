#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PosterBoardDatabase : NSObject
+ (BOOL)prepareDatabaseAtPath:(NSString *)path
                       walData:(nullable NSData *)walData
                  wallpaperUUID:(NSString *)uuid
                       provider:(NSString *)provider
                          error:(NSString * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
