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
    
    NSString *_stateDir;
    NSString *_stateFile;
    NSFileManager *_fileManager;

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
    _bufferSize    = OEIntSizeMake(640, 480);
    _frameInterval = 60;
    _fileManager   = [NSFileManager new];
    
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
    _screenRect = { {0,0}, {640, 480} };
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
    
    _frameInterval = fps;
    
    // initialize joysticks
    
    for (int i = 0; i < 8; i++) {
        NSString *name = [NSString stringWithFormat:@"OpenEmu Device %d", i];
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
    InputDevice *kb = [_osd.keyboard addDeviceNamed:@"OpenEmu Keys"];
    [kb addItemNamed:@"Service" id:InputItemID_F2 getter:joystick_get_state context:&_buttons[0][OEArcadeButtonService]];
}

- (void)updateAudioBuffer:(const int16_t *)buffer samples:(NSInteger)samples
{
    id<OEAudioBuffer> buf = [self audioBufferAtIndex:0];
    [buf write:buffer maxLength:samples * 2 * sizeof(int16_t)];
}

#pragma mark - Execution

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    [_osd setBasePath:[[path stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]];
    NSString *rom = [[path lastPathComponent] stringByDeletingPathExtension];
    BOOL res = [_osd loadGame:rom error:error];
    return [_osd loadGame:rom];
}

- (void)resetEmulation
{
    [_osd scheduleSoftReset];
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
