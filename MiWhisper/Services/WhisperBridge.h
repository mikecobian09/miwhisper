#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WhisperBridge : NSObject

- (nullable NSString *)transcribeAudioAtPath:(NSString *)audioPath
                                   modelPath:(NSString *)modelPath
                                    language:(NSString *)language
                          translateToEnglish:(BOOL)translateToEnglish
                                       error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
