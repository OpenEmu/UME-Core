/*
 Copyright (c) 2013, OpenEmu Team
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "MAMEGameCore.h"

#import <OpenEmuBase/OERingBuffer.h>
#import <OpenGL/gl.h>
#import <dlfcn.h>

@interface MAMEGameCore () <OEArcadeSystemResponderClient>
{
    uint32_t _buttons[8][OEArcadeButtonCount];
    uint32_t _axes[8][InputMaxAxis];
    
    uint32_t *_buffer;
    OEIntSize _bufferSize;
    OEIntRect _screenRect;
    OEIntSize _aspectSize;
    
    NSTimeInterval _frameInterval;
    

    // dylib
    void *_handle;
    OSD *_osd;
    
}

@end

static uint32_t joystick_get_state(void *device_internal, void *item_internal)
{
    return *(uint32_t *)item_internal;
}

@implementation MAMEGameCore

#pragma mark - Lifecycle

- (id)init
{
    self = [super init];
    if(!self)
    {
        return nil;
    }

    // Sensible defaults
    _bufferSize    = OEIntSizeMake(1024, 1024);
    _frameInterval = 60;
    
#if 1
#define LIB "/Volumes/Data/projects/mame/cmake-build-headless-dbg/build/projects/headless/mametiny/cmake/mametiny/libmametiny_headless.dylib"
#else
#define LIB "/Volumes/Data/projects/mame/mamearcade_headless.dylib"
#endif
    
//    _handle = dlopen(LIB, RTLD_LAZY);
//    if (_handle == nil)
//    {
//        NSLog(@"No library: %s", dlerror());
//        return nil;
//    }
    
//    Class OSD_class = NSClassFromString(@"OSD");
//    if (!OSD_class)
//    {
//        NSLog(@"unable to load OSD class");
//        return nil;
//    }
    
    
    
    _osd = [OSD shared];
    _osd.delegate = self;
    _osd.verboseOutput = YES; // TODO: debug only; remove later
    _screenRect = { {0,0}, {1024, 1024} };
    _aspectSize = { 4, 3 };

    return self;
}

- (void)dealloc
{
    dlclose(_handle);
}

#pragma mark - OSDDelegate

- (void)willInitializeWithBounds:(NSSize)bounds fps:(float)fps aspect:(NSSize)aspect
{
    _screenRect = {{0, 0}, OEIntSizeMake(bounds.width, bounds.height)};
    _aspectSize = OEIntSizeMake(aspect.width, aspect.height);
    if (_buffer != nil)
    {
        [_osd setBuffer:_buffer size:NSSizeFromOEIntSize(_bufferSize)];
    }

    _frameInterval = fps;
    
    // initialize joysticks
    
    for (int i = 0; i < 8; i++) {
        NSString *name = [NSString stringWithFormat:@"OpenEmu Player %d", i];
        InputDevice *dev = [_osd.joystick addDeviceNamed:name];
        [dev addItemNamed:@"X Axis" id:InputItemID_XAXIS getter:joystick_get_state context:&_axes[i][0]];
        [dev addItemNamed:@"Y Axis" id:InputItemID_YAXIS getter:joystick_get_state context:&_axes[i][1]];
        [dev addItemNamed:@"Start" id:InputItemID_START getter:joystick_get_state context:&_buttons[i][OEArcadeButtonP1Start]];
        [dev addItemNamed:@"Insert Coin" id:InputItemID_SELECT getter:joystick_get_state context:&_buttons[i][OEArcadeButtonInsertCoin]];
        [dev addItemNamed:@"Button 1" id:InputItemID_BUTTON1 getter:joystick_get_state context:&_buttons[i][OEArcadeButton1]];
        [dev addItemNamed:@"Button 2" id:InputItemID_BUTTON2 getter:joystick_get_state context:&_buttons[i][OEArcadeButton2]];
        [dev addItemNamed:@"Button 3" id:InputItemID_BUTTON3 getter:joystick_get_state context:&_buttons[i][OEArcadeButton3]];
        [dev addItemNamed:@"Button 4" id:InputItemID_BUTTON4 getter:joystick_get_state context:&_buttons[i][OEArcadeButton4]];
        [dev addItemNamed:@"Button 5" id:InputItemID_BUTTON5 getter:joystick_get_state context:&_buttons[i][OEArcadeButton5]];
        [dev addItemNamed:@"Button 6" id:InputItemID_BUTTON6 getter:joystick_get_state context:&_buttons[i][OEArcadeButton6]];
    }
    
    // Special keys
    InputDevice *kb = [_osd.keyboard addDeviceNamed:@"OpenEmu Keyboard"];
    [kb addItemNamed:@"Service" id:InputItemID_F2 getter:joystick_get_state context:&_buttons[0][OEArcadeButtonService]];
    [kb addItemNamed:@"UI Configure" id:InputItemID_TAB getter:joystick_get_state context:&_buttons[0][OEArcadeUIConfigure]];
}

- (void)updateAudioBuffer:(const int16_t *)buffer samples:(NSInteger)samples
{
    id<OEAudioBuffer> buf = [self audioBufferAtIndex:0];
    [buf write:buffer maxLength:samples * 2 * sizeof(int16_t)];
}

- (void)logLevel:(OSDLogLevel)level message:(NSString *)msg
{
    NSLog(@"%@", msg);
}

#pragma mark - Execution

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    NSString *romDir = [path stringByDeletingLastPathComponent];
    //[_osd setBasePath:[romDir stringByDeletingLastPathComponent]];
    [_osd setBasePath:self.supportDirectoryPath];
    _osd.romsPath = romDir;
    NSString *rom = [[path lastPathComponent] stringByDeletingPathExtension];
    BOOL success = [_osd loadGame:rom error:error];
    if (!success && error != nil && *error != nil)
    {
        *error = [self normalizeError:*error forRomDir:romDir forDriver:rom];
        return NO;
    }
    return success;
}

- (NSError *)normalizeError:(NSError *)error forRomDir:(NSString *)romDir forDriver:(NSString *)driver
{
    NSURL *romDirURL = [NSURL fileURLWithPath:romDir isDirectory:YES];
    NSLog(@"MAME: Audit failed with output:\n%@", error.localizedFailureReason);
    NSString *auditOutput = error.localizedFailureReason;
    
    // Parse MAME's audit report and build a list of missing/incomplete required files
    NSMutableOrderedSet *missingFilesSet = [NSMutableOrderedSet new];

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?<=NOT FOUND \\()(.*?)(?=\\)\n)|(?<=: )([^\\s]+)(.*?)(?= - NOT FOUND\n)" options:NSRegularExpressionCaseInsensitive error:nil];

    NSString *gameDriverName = _osd.driverName;

    [regex enumerateMatchesInString:auditOutput options:0 range:NSMakeRange(0, auditOutput.length) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
        if (result == nil) return;

        NSRange range = result.range;
        NSRange secondGroup = [result rangeAtIndex:2];
        NSRange thirdGroup  = [result rangeAtIndex:3];

        NSString *match = [auditOutput substringWithRange:range];
        NSMutableString *fileName = [NSMutableString stringWithString:match];

        // Assumed missing/incomplete parent, device or BIOS ROM
        if(secondGroup.location == NSNotFound && thirdGroup.location == NSNotFound)
        {
            [fileName appendString:@".zip"];
        }
        // Assumed missing CHD
        else if(secondGroup.location != NSNotFound && [auditOutput substringWithRange:thirdGroup].length == 0)
        {
            [fileName appendString:@".chd"];

        }
        // Assumed driver/clone ROM loaded is missing files
        else
        {
            //NSString *match = [auditOutput substringWithRange:secondGroup];
            fileName = [NSMutableString stringWithFormat:@"%@.zip", gameDriverName];
        }

        [missingFilesSet addObject:fileName];
    }];

    // Sort missing files by ascending order
    NSSortDescriptor *sortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"self"
                                                                     ascending:YES];
    [missingFilesSet sortUsingDescriptors:@[sortDescriptor]];

    // Determine if ROMs exist with missing files, or are not found
    NSMutableString *missingFilesList = [NSMutableString string];
    for(NSString *missingFile in missingFilesSet)
    {
        NSURL *missingFileURL = [romDirURL URLByAppendingPathComponent:missingFile];

        if([missingFileURL checkResourceIsReachableAndReturnError:nil])
        {
            [missingFilesList appendString:[NSString stringWithFormat:@"%@  \t- INCORRECT SET\n", missingFile]];
        }
        else
        {
            [missingFilesList appendString:[NSString stringWithFormat:@"%@  \t- NOT FOUND\n", missingFile]];
        }
    }

    // Give an audit report to the user
    NSString *game = [NSString stringWithFormat:@"%@ (%@.zip)", _osd.driverFullName, _osd.driverName];
    NSString *versionRequired = [[[[[self owner] bundle] infoDictionary] objectForKey:@"CFBundleVersion"] substringToIndex:5];

    NSError *outErr = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:@{
        NSLocalizedDescriptionKey : @"Required files are missing.",
        NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"%@ requires:\n\n%@\nThese ROMs must be from a MAME %@ ROM set. Some of these files can be parent/device/BIOS ROMs, which are not part of the game, but are still required. Delete files already imported and reimport with correct files.", game, missingFilesList, versionRequired],
        }];

    return outErr;
}

- (void)resetEmulation
{
    [_osd scheduleHardReset];
}

#pragma mark - Video

- (const void *)getVideoBufferWithHint:(void *)hint
{
    _buffer = (uint32_t *)hint;
    [_osd setBuffer:hint size:NSSizeFromOEIntSize(_bufferSize)];
    return _buffer;
}

- (OEIntSize)bufferSize
{
    return _bufferSize;
}

- (OEIntRect)screenRect {
    return _screenRect;
}

- (OEIntSize)aspectSize
{
    return _aspectSize;
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

#pragma mark - execution

- (void)executeFrame
{
    [_osd execute];
}

- (void)stopEmulation
{
    [_osd unload];
    _osd.delegate = nil;
    [super stopEmulation];
}

- (NSTimeInterval)frameInterval
{
    return _frameInterval;
}

#pragma mark - Audio

- (double)audioSampleRate
{
    return 48000;
}

- (NSUInteger)channelCount
{
    return 2;
}

#pragma mark - Input

- (void)setState:(BOOL)pressed ofButton:(OEArcadeButton)button forPlayer:(NSUInteger)player
{
    _buttons[player-1][button] = pressed ? 1 : 0;
    _axes[player-1][0] = _buttons[player-1][OEArcadeButtonLeft] ? InputAbsoluteMin : (_buttons[player-1][OEArcadeButtonRight] ? InputAbsoluteMax : 0);
    _axes[player-1][1] = _buttons[player-1][OEArcadeButtonUp] ? InputAbsoluteMin : (_buttons[player-1][OEArcadeButtonDown] ? InputAbsoluteMax : 0);
}

- (oneway void)didPushArcadeButton:(OEArcadeButton)button forPlayer:(NSUInteger)player
{
    [self setState:YES ofButton:button forPlayer:player];
}

- (oneway void)didReleaseArcadeButton:(OEArcadeButton)button forPlayer:(NSUInteger)player
{
    [self setState:NO ofButton:button forPlayer:player];
}

#pragma mark - Save State

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    BOOL res     = NO;
    NSError *err = nil;
    
    if (_osd.supportsSave)
    {
        res = [_osd saveStateFromFileAtPath:fileName error:&err];
    }
    
    block(res, err);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    BOOL res     = NO;
    NSError *err = nil;
    
    if (_osd.supportsSave)
    {
        res = [_osd loadStateFromFileAtPath:fileName error:&err];
    }
    
    block(res, err);
}

- (BOOL)supportsRewinding
{
    return _osd.supportsSave;
}

- (NSData *)serializeStateWithError:(NSError *__autoreleasing *)outError
{
    return [_osd serializeState];
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError *__autoreleasing *)outError
{
    return [_osd deserializeState:state];
}

@end
