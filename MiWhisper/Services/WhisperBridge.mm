#import "WhisperBridge.h"

#import "whisper.h"

#include <algorithm>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace {
constexpr uint32_t kWavRiff = 0x46464952; // RIFF
constexpr uint32_t kWavWave = 0x45564157; // WAVE
constexpr uint32_t kWavFmt  = 0x20746d66; // fmt
constexpr uint32_t kWavData = 0x61746164; // data
constexpr size_t kMinWhisperSamples = WHISPER_SAMPLE_RATE / 10;   // 100 ms
constexpr size_t kPreferredSamples = WHISPER_SAMPLE_RATE * 3 / 10; // 300 ms

uint32_t read_u32(const uint8_t * bytes) {
    return uint32_t(bytes[0]) |
        (uint32_t(bytes[1]) << 8) |
        (uint32_t(bytes[2]) << 16) |
        (uint32_t(bytes[3]) << 24);
}

uint16_t read_u16(const uint8_t * bytes) {
    return uint16_t(bytes[0]) | (uint16_t(bytes[1]) << 8);
}

NSError * makeError(NSInteger code, NSString * description) {
    return [NSError errorWithDomain:@"MiWhisper.WhisperBridge" code:code userInfo:@{
        NSLocalizedDescriptionKey: description
    }];
}

bool loadPCMFromWav(NSString * path, std::vector<float> & samples, NSError ** error) {
    NSLog(@"[MiWhisper][WhisperBridge] loadPCMFromWav start path=%@", path);
    NSData * data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (data == nil) {
        NSLog(@"[MiWhisper][WhisperBridge] failed to read WAV path=%@ error=%@", path, error && *error ? (*error).localizedDescription : @"unknown");
        return false;
    }

    if (data.length < 44) {
        NSLog(@"[MiWhisper][WhisperBridge] WAV shorter than header size path=%@ sizeBytes=%lu", path, (unsigned long)data.length);
        if (error) {
            *error = makeError(10, @"The recorded WAV file is too short.");
        }
        return false;
    }

    const uint8_t * bytes = static_cast<const uint8_t *>(data.bytes);
    if (read_u32(bytes) != kWavRiff || read_u32(bytes + 8) != kWavWave) {
        NSLog(@"[MiWhisper][WhisperBridge] invalid RIFF/WAVE header path=%@", path);
        if (error) {
            *error = makeError(11, @"The audio file is not a valid RIFF/WAVE file.");
        }
        return false;
    }

    uint16_t audioFormat = 0;
    uint16_t channels = 0;
    uint32_t sampleRate = 0;
    uint16_t bitsPerSample = 0;
    const uint8_t * pcmBytes = nullptr;
    uint32_t pcmLength = 0;

    size_t offset = 12;
    while (offset + 8 <= data.length) {
        const uint32_t chunkID = read_u32(bytes + offset);
        const uint32_t chunkSize = read_u32(bytes + offset + 4);
        const size_t chunkStart = offset + 8;
        const size_t nextOffset = chunkStart + chunkSize + (chunkSize % 2);

        if (nextOffset > data.length) {
            break;
        }

        if (chunkID == kWavFmt && chunkSize >= 16) {
            const uint8_t * fmt = bytes + chunkStart;
            audioFormat = read_u16(fmt + 0);
            channels = read_u16(fmt + 2);
            sampleRate = read_u32(fmt + 4);
            bitsPerSample = read_u16(fmt + 14);
        } else if (chunkID == kWavData) {
            pcmBytes = bytes + chunkStart;
            pcmLength = chunkSize;
        }

        offset = nextOffset;
    }

    if (audioFormat != 1 || channels != 1 || sampleRate != WHISPER_SAMPLE_RATE || bitsPerSample != 16) {
        NSLog(
            @"[MiWhisper][WhisperBridge] unexpected WAV format path=%@ audioFormat=%u channels=%u sampleRate=%u bitsPerSample=%u",
            path,
            audioFormat,
            channels,
            sampleRate,
            bitsPerSample
        );
        if (error) {
            *error = makeError(12, @"MiWhisper expects 16 kHz mono 16-bit PCM WAV input.");
        }
        return false;
    }

    if (pcmBytes == nullptr || pcmLength == 0 || (pcmLength % 2) != 0) {
        NSLog(
            @"[MiWhisper][WhisperBridge] invalid PCM chunk path=%@ pcmBytesPresent=%@ pcmLength=%u",
            path,
            pcmBytes != nullptr ? @"true" : @"false",
            pcmLength
        );
        if (error) {
            *error = makeError(13, @"The WAV file does not contain valid PCM audio data.");
        }
        return false;
    }

    const int16_t * pcm = reinterpret_cast<const int16_t *>(pcmBytes);
    const size_t sampleCount = pcmLength / sizeof(int16_t);
    samples.resize(sampleCount);

    for (size_t i = 0; i < sampleCount; ++i) {
        samples[i] = std::max(-1.0f, std::min(1.0f, float(pcm[i]) / 32768.0f));
    }

    const double durationMsBeforePadding = (double(sampleCount) / double(WHISPER_SAMPLE_RATE)) * 1000.0;
    if (samples.size() < kMinWhisperSamples) {
        NSLog(
            @"[MiWhisper][WhisperBridge] WAV below whisper threshold path=%@ samples=%lu durationMs=%.1f paddingToSamples=%lu",
            path,
            (unsigned long)sampleCount,
            durationMsBeforePadding,
            (unsigned long)kPreferredSamples
        );
        samples.resize(kPreferredSamples, 0.0f);
    }

    NSLog(
        @"[MiWhisper][WhisperBridge] WAV ready path=%@ sizeBytes=%lu sampleRate=%u channels=%u bitsPerSample=%u samples=%lu durationMsBeforePadding=%.1f durationMsAfterPadding=%.1f",
        path,
        (unsigned long)data.length,
        sampleRate,
        channels,
        bitsPerSample,
        (unsigned long)samples.size(),
        durationMsBeforePadding,
        (double(samples.size()) / double(WHISPER_SAMPLE_RATE)) * 1000.0
    );

    return true;
}
} // namespace

@implementation WhisperBridge {
    struct whisper_context * _context;
    NSString * _loadedModelPath;
    NSLock * _lock;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _context = nullptr;
        _loadedModelPath = nil;
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (void)dealloc {
    if (_context != nullptr) {
        whisper_free(_context);
        _context = nullptr;
    }
}

- (BOOL)ensureModelLoadedAtPath:(NSString *)modelPath error:(NSError **)error {
    if (_context != nullptr && [_loadedModelPath isEqualToString:modelPath]) {
        NSLog(@"[MiWhisper][WhisperBridge] reusing loaded model path=%@", modelPath);
        return YES;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
        NSLog(@"[MiWhisper][WhisperBridge] model missing path=%@", modelPath);
        if (error) {
            *error = makeError(20, [NSString stringWithFormat:@"Missing Whisper model at %@.", modelPath]);
        }
        return NO;
    }

    if (_context != nullptr) {
        whisper_free(_context);
        _context = nullptr;
        _loadedModelPath = nil;
    }

    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = true;

    NSLog(@"[MiWhisper][WhisperBridge] loading model path=%@ useGPU=true", modelPath);
    _context = whisper_init_from_file_with_params(modelPath.UTF8String, cparams);
    if (_context == nullptr) {
        NSLog(@"[MiWhisper][WhisperBridge] failed to load model path=%@", modelPath);
        if (error) {
            *error = makeError(21, [NSString stringWithFormat:@"Failed to load Whisper model at %@.", modelPath]);
        }
        return NO;
    }

    _loadedModelPath = [modelPath copy];
    return YES;
}

- (nullable NSString *)transcribeAudioAtPath:(NSString *)audioPath
                                   modelPath:(NSString *)modelPath
                                    language:(NSString *)language
                          translateToEnglish:(BOOL)translateToEnglish
                                       error:(NSError **)error {
    [_lock lock];
    @try {
        if (![self ensureModelLoadedAtPath:modelPath error:error]) {
            return nil;
        }

        std::vector<float> samples;
        if (!loadPCMFromWav(audioPath, samples, error)) {
            return nil;
        }

        whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        params.n_threads = std::max(1, std::min(8, int([[NSProcessInfo processInfo] activeProcessorCount])));
        params.no_context = true;
        params.no_timestamps = true;
        params.single_segment = true;
        params.print_special = false;
        params.print_progress = false;
        params.print_realtime = false;
        params.print_timestamps = false;
        params.translate = translateToEnglish;
        params.suppress_blank = true;
        params.suppress_nst = true;
        params.no_speech_thold = 1.0f;

        const bool autoLanguage = language.length == 0 || [language isEqualToString:@"auto"];
        params.language = autoLanguage ? "auto" : language.UTF8String;
        params.detect_language = false;

        NSLog(
            @"[MiWhisper][WhisperBridge] whisper_full start audio=%@ model=%@ autoLanguage=%@ detectLanguage=%@ language=%@ translate=%@ noSpeechThold=%.2f samples=%lu durationMs=%.1f threads=%d",
            audioPath,
            modelPath.lastPathComponent,
            autoLanguage ? @"true" : @"false",
            params.detect_language ? @"true" : @"false",
            autoLanguage ? @"auto" : language,
            params.translate ? @"true" : @"false",
            params.no_speech_thold,
            (unsigned long)samples.size(),
            (double(samples.size()) / double(WHISPER_SAMPLE_RATE)) * 1000.0,
            params.n_threads
        );

        const int whisperResult = whisper_full(_context, params, samples.data(), int(samples.size()));
        if (whisperResult != 0) {
            NSLog(@"[MiWhisper][WhisperBridge] whisper_full failed rc=%d", whisperResult);
            if (error) {
                *error = makeError(22, @"whisper.cpp failed while processing the audio.");
            }
            return nil;
        }

        NSMutableArray<NSString *> * segments = [NSMutableArray array];
        const int segmentCount = whisper_full_n_segments(_context);
        for (int index = 0; index < segmentCount; ++index) {
            const char * rawText = whisper_full_get_segment_text(_context, index);
            if (rawText == nullptr) {
                continue;
            }

            NSString * text = [[NSString stringWithUTF8String:rawText] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (text.length > 0) {
                [segments addObject:text];
            }
        }

        NSString * transcript = [[segments componentsJoinedByString:@" "] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        const int detectedLangID = whisper_full_lang_id(_context);
        const char * detectedLang = detectedLangID >= 0 ? whisper_lang_str(detectedLangID) : nullptr;
        NSLog(
            @"[MiWhisper][WhisperBridge] whisper_full success segments=%d transcriptChars=%lu detectedLanguage=%@",
            segmentCount,
            (unsigned long)transcript.length,
            detectedLang != nullptr ? [NSString stringWithUTF8String:detectedLang] : @"unknown"
        );
        if (transcript.length == 0) {
            if (error) {
                *error = makeError(23, @"The transcript came back empty.");
            }
            return nil;
        }

        return transcript;
    } @finally {
        [_lock unlock];
    }
}

@end
