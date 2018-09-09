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

#include "emu.h"
#include "emuopts.h"
#include "audit.h"
#include "mame.h"

#include "sdl/sdlsync.h"

#include "osx_osd_interface.h"

@interface MAMEGameCore () <OEArcadeSystemResponderClient>
{
    running_machine *_machine;
    render_target *_target;
    render_target *_uiTarget;
    INT32 _buttons[8][OEArcadeButtonCount];
    INT32 _axes[8][INPUT_MAX_AXIS];
    osd_event *_renderEvent;
    osd_event *_exitEvent;

    GLuint _texture;
    GLuint _textureWidth;
    GLuint _textureHeight;
    uint32_t *_buffer;

    NSString *_romDir;
    NSString *_driverName;

    NSTimeInterval _frameInterval;
    OEIntSize _bufferSize;

    BOOL _initializing;
}
@end

static void output_callback(delegate_late_bind *param, const char *format, va_list argptr)
{
    NSLog(@"MAME: %@", [[NSString alloc] initWithFormat:[NSString stringWithUTF8String:format] arguments:argptr]);
}

static void error_callback(running_machine &machine, const char *string)
{
    //NSLog(@"MAME: %s", string);
}

static void mame_did_exit(running_machine *machine)
{
    osx_osd_interface &interface = dynamic_cast<osx_osd_interface &>(machine->osd());
    [interface.core() osd_exit:machine];
}

static INT32 joystick_get_state(void *device_internal, void *item_internal)
{
    return *(INT32 *)item_internal;
}

@implementation MAMEGameCore

#pragma mark - Lifecycle

+ (void)initialize
{
    mame_set_output_channel(OUTPUT_CHANNEL_ERROR, output_delegate(FUNC(output_callback), (delegate_late_bind *)NULL));
    mame_set_output_channel(OUTPUT_CHANNEL_WARNING, output_delegate(FUNC(output_callback), (delegate_late_bind *)NULL));
    mame_set_output_channel(OUTPUT_CHANNEL_INFO, output_delegate(FUNC(output_callback), (delegate_late_bind *)NULL));
    mame_set_output_channel(OUTPUT_CHANNEL_DEBUG, output_delegate(FUNC(output_callback), (delegate_late_bind *)NULL));
    mame_set_output_channel(OUTPUT_CHANNEL_VERBOSE, output_delegate(FUNC(output_callback), (delegate_late_bind *)NULL));
    mame_set_output_channel(OUTPUT_CHANNEL_LOG, output_delegate(FUNC(output_callback), (delegate_late_bind *)NULL));
}

- (id)init
{
    self = [super init];
    if(!self)
    {
        return nil;
    }

    _initializing = YES;

    _renderEvent = osd_event_alloc(FALSE, FALSE);
    _exitEvent   = osd_event_alloc(FALSE, FALSE);
    
    // Sensible defaults
    _bufferSize = OEIntSizeMake(640, 480);
    _frameInterval = 60;

    return self;
}

- (void)dealloc
{
    osd_event_free(_renderEvent);
    osd_event_free(_exitEvent);

    if(_buffer)
    {
        free(_buffer);
        _buffer = NULL;
    }
}

- (void)osd_init:(running_machine *)machine
{
    _machine = machine;

    _machine->add_notifier(MACHINE_NOTIFY_EXIT, machine_notify_delegate(FUNC(mame_did_exit), machine));
    _machine->add_logerror_callback(error_callback);
    _machine->save().register_postsave(save_prepost_delegate(FUNC(_OESaveStateCallback), machine));
    _machine->save().register_postload(save_prepost_delegate(FUNC(_OESaveStateCallback), machine));

    _target = _machine->render().target_alloc();

    _frameInterval = (NSTimeInterval) ATTOSECONDS_PER_SECOND / _machine->primary_screen->refresh_attoseconds();
    NSLog(@"Refresh rate set to %f Hz", _frameInterval);
    
    INT32 width = 0, height = 0;
    _target->compute_minimum_size(width, height);
    if(width > 0 && height > 0) _bufferSize = OEIntSizeMake(width, height);
    _target->set_bounds(_bufferSize.width, _bufferSize.height);

    _uiTarget = _machine->render().target_alloc();
    _target->manager().set_ui_target(*_uiTarget);

    // Add devices for 8 players
    for (int i = 0; i < 8; i++) {
        input_device *input = _machine->input().device_class(DEVICE_CLASS_JOYSTICK).add_device([[NSString stringWithFormat:@"OpenEmu Device %d", i] UTF8String], NULL);
        input->add_item("X Axis", ITEM_ID_XAXIS, joystick_get_state, &_axes[i][0]);
        input->add_item("Y Axis", ITEM_ID_YAXIS, joystick_get_state, &_axes[i][1]);
        input->add_item("Start", ITEM_ID_START, joystick_get_state, &_buttons[i][OEArcadeButtonP1Start]);
        input->add_item("Select", ITEM_ID_SELECT, joystick_get_state, &_buttons[i][OEArcadeButtonInsertCoin]);
        input->add_item("Button 1", ITEM_ID_BUTTON1, joystick_get_state, &_buttons[i][OEArcadeButton1]);
        input->add_item("Button 2", ITEM_ID_BUTTON2, joystick_get_state, &_buttons[i][OEArcadeButton2]);
        input->add_item("Button 3", ITEM_ID_BUTTON3, joystick_get_state, &_buttons[i][OEArcadeButton3]);
        input->add_item("Button 4", ITEM_ID_BUTTON4, joystick_get_state, &_buttons[i][OEArcadeButton4]);
        input->add_item("Button 5", ITEM_ID_BUTTON5, joystick_get_state, &_buttons[i][OEArcadeButton5]);
        input->add_item("Button 6", ITEM_ID_BUTTON6, joystick_get_state, &_buttons[i][OEArcadeButton6]);
    }
    
    // Special keys
    input_device *inputKeys = _machine->input().device_class(DEVICE_CLASS_KEYBOARD).add_device("OpenEmu Keys", NULL);
    inputKeys->add_item("Service", ITEM_ID_F2, joystick_get_state, &_buttons[0][OEArcadeButtonService]);

    _initializing = NO;
}

- (void)osd_exit:(running_machine *)machine
{
    NSParameterAssert(_machine == machine);

    _machine->render().target_free(_target);
    _machine->render().target_free(_uiTarget);
    _target = NULL;
    _uiTarget = NULL;

    _machine = NULL;

    osd_event_set(_exitEvent);
}

#pragma mark - Execution

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    _romDir = [path stringByDeletingLastPathComponent];
    if(!_romDir) return NO;

    // Need a better way to identify the ROM driver from the archive path

    // The code below works by hashing the individual files and checking each
    // but takes *forever* and does not scale at O(n)
    //media_identifier ident(options);
    //ident.identify([path cStringUsingEncoding:NSUTF8StringEncoding]);
    //NSLog(@"I found this many matches: %i", ident.matches());

    // The temporary solution is to take the file basename
    // Easily broken by misnamed ROM archives
    _driverName = [[path lastPathComponent] stringByDeletingPathExtension];

    astring err;
    emu_options options = emu_options();
    options.set_value(OPTION_MEDIAPATH, [_romDir UTF8String], OPTION_PRIORITY_HIGH, err);

    game_driver driver;
    driver_enumerator drivlist(options, [_driverName UTF8String]);
    media_auditor auditor(drivlist);

    BOOL verified = NO;
    while(drivlist.next() && !verified)
    {
        media_auditor::summary summary = auditor.audit_media(AUDIT_VALIDATE_FAST);
        if(summary == media_auditor::CORRECT || summary == media_auditor::BEST_AVAILABLE)
        {
            driver = drivlist.driver();
            verified = YES;

            [NSThread detachNewThreadSelector:@selector(mameEmuThread) toTarget:self withObject:nil];
        }
        else
        {
            astring *output = new astring();
            auditor.summarize(drivlist.driver().name, output);
            NSLog(@"MAME: Audit failed with output:\n%s", output->cstr());
            delete output;
        }
    }

    return verified;
}

// FIXME: Weird bug. This is not being called when restoring an autosave state on launch.
//- (void)startEmulation
//{
//    [super startEmulation];
//    [NSThread detachNewThreadSelector:@selector(mameEmuThread) toTarget:self withObject:nil];
//}

- (void)stopEmulation
{
    if(_machine != NULL) _machine->schedule_exit();

    // Wait for MAME to shut down correctly
    osd_event_wait(_exitEvent, osd_ticks_per_second() * 10);

    if(_texture)
    {
        glDeleteTextures(1, &_texture);
        _texture = 0;
    }

    [super stopEmulation];
}

- (void)setPauseEmulation:(BOOL)pauseEmulation
{
    if(_machine != NULL)
    {
        if(pauseEmulation) _machine->pause();
        else _machine->resume();
    }

    [super setPauseEmulation:pauseEmulation];
}

- (void)resetEmulation
{
    if(_machine != NULL) _machine->schedule_hard_reset();
}

- (void)mameEmuThread
{
    astring err;

    emu_options options = emu_options();    
    options.set_value(OPTION_MEDIAPATH, [_romDir UTF8String], OPTION_PRIORITY_HIGH, err);
    options.set_value(OPTION_SAMPLEPATH, 
                      [[[self supportDirectoryPath] stringByAppendingPathComponent:@"samples"] UTF8String], 
                      OPTION_PRIORITY_HIGH, err);
    options.set_value(OPTION_CFG_DIRECTORY,
                      [[[self supportDirectoryPath] stringByAppendingPathComponent:@"cfg"] UTF8String],
                      OPTION_PRIORITY_HIGH, err);
    options.set_value(OPTION_NVRAM_DIRECTORY,
                      [[[self supportDirectoryPath] stringByAppendingPathComponent:@"nvram"]UTF8String],
                      OPTION_PRIORITY_HIGH, err);
    options.set_value(OPTION_MEMCARD_DIRECTORY,
                      [[[self supportDirectoryPath] stringByAppendingPathComponent:@"memcard"] UTF8String],
                      OPTION_PRIORITY_HIGH, err);
    options.set_value(OPTION_INPUT_DIRECTORY,
                      [[[self supportDirectoryPath] stringByAppendingPathComponent:@"inp"] UTF8String],
                      OPTION_PRIORITY_HIGH, err);
    options.set_value(OPTION_DIFF_DIRECTORY,
                      [[[self supportDirectoryPath] stringByAppendingPathComponent:@"diff"] UTF8String],
                      OPTION_PRIORITY_HIGH, err);
    options.set_value(OPTION_COMMENT_DIRECTORY,
                      [[[self supportDirectoryPath] stringByAppendingPathComponent:@"comments"] UTF8String],
                      OPTION_PRIORITY_HIGH, err);

    options.set_value(OPTION_SYSTEMNAME, [_driverName UTF8String], OPTION_PRIORITY_HIGH, err);
    options.set_value(OPTION_SAMPLERATE, (int)[self audioSampleRate], OPTION_PRIORITY_HIGH, err);
    options.set_value(OPTION_SKIP_GAMEINFO, true, OPTION_PRIORITY_HIGH, err);
#ifdef DEBUG
    options.set_value(OPTION_VERBOSE, true, OPTION_PRIORITY_HIGH, err);
    options.set_value(OPTION_LOG, true, OPTION_PRIORITY_HIGH, err);
#endif

    osx_osd_interface interface = osx_osd_interface(self);

    DLog(@"MAME: Starting game execution thread");
    
    mame_execute(options, interface);

    DLog(@"MAME: Game execution thread exiting");
}

#pragma mark - Video

- (OEGameCoreRendering)gameCoreRendering
{
    return OEGameCoreRenderingOpenGL2Video;
}

- (OEIntSize)bufferSize
{
    return _bufferSize;
}

- (OEIntSize)aspectSize
{
    if(_machine != NULL)
    {
        switch(_machine->system().flags & ORIENTATION_MASK)
        {
            case ROT0:
            case ROT180:
                return OEIntSizeMake(4, 3);
                break;

            case ROT90:
            case ROT270:
                return OEIntSizeMake(3, 4);
                break;

            default:
                break;
        }
    }

    return OEIntSizeMake(4, 3);
}

- (void)osd_update:(bool)skip_redraw
{
    osd_event_set(_renderEvent);

    if (!skip_redraw && !_machine->save_or_load_pending())
    {
        osd_event_set(_renderEvent);
    }
}

- (void)executeFrame
{
    if(self.shouldSkipFrame || _target == NULL) return;

    // Only wait for 5 frames or so maximum
    int status = osd_event_wait(_renderEvent, 5 * (osd_ticks_per_second() / self.frameInterval));
    if(status == FALSE) return;

    if(!_texture)
    {
        glEnable(GL_TEXTURE_RECTANGLE_EXT);
        glGenTextures(1, &_texture);
    }
    
    glHint(GL_PERSPECTIVE_CORRECTION_HINT, GL_NICEST);
    glDisable(GL_DEPTH_TEST);
    glClear(GL_COLOR_BUFFER_BIT);

    glViewport(0.0, 0.0, (GLsizei)_bufferSize.width, (GLsizei)_bufferSize.height);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0.0, (GLdouble)_bufferSize.width, (GLdouble)_bufferSize.height, 0.0, 0.0, -1.0);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();

    glEnableClientState(GL_VERTEX_ARRAY);

    render_primitive_list &primitives = _target->get_primitives();
    primitives.acquire_lock();
    for(render_primitive *prim = primitives.first(); prim != NULL; prim = prim->next())
    {
        GLfloat color[4];
        color[0] = prim->color.r;
        color[1] = prim->color.g;
        color[2] = prim->color.b;
        color[3] = prim->color.a;

        switch(PRIMFLAG_GET_BLENDMODE(prim->flags))
        {
            case BLENDMODE_NONE:
                glDisable(GL_BLEND);
                break;
            case BLENDMODE_ALPHA:
                glEnable(GL_BLEND);
                glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
                break;
            case BLENDMODE_RGB_MULTIPLY:
                glEnable(GL_BLEND);
                glBlendFunc(GL_DST_COLOR, GL_ZERO);
                break;
            case BLENDMODE_ADD:
                glEnable(GL_BLEND);
                glBlendFunc(GL_SRC_ALPHA, GL_ONE);
                break;
            default:
                break;
        }

        if(prim->type == render_primitive::LINE)
        {
            GLfloat vertices[] = { prim->bounds.x0, prim->bounds.y0, prim->bounds.x1, prim->bounds.y1 };

            glColor4fv(color);
            BOOL line = ((prim->bounds.x1 != prim->bounds.x0) || (prim->bounds.y1 != prim->bounds.y0));
            if(line) glLineWidth(prim->width);
            else glPointSize(prim->width);

            glVertexPointer(2, GL_FLOAT, 0, vertices);
            if(line) glDrawArrays(GL_LINES, 0, 2);
            else glDrawArrays(GL_POINTS, 0, 1);
        }
        else if(prim->type == render_primitive::QUAD)
        {
            GLfloat vertices[] = { prim->bounds.x0, prim->bounds.y1,
                                   prim->bounds.x0, prim->bounds.y0,
                                   prim->bounds.x1, prim->bounds.y1,
                                   prim->bounds.x1, prim->bounds.y0 };
            glVertexPointer(2, GL_FLOAT, 0, vertices);

            if(prim->texture.base == NULL)
            {
                glColor4fv(color);
                glLineWidth(1.0f);
                glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
            }
            else
            {
                render_texinfo texinfo = prim->texture;
                unsigned int width = texinfo.width, height = texinfo.height, rowpixels = texinfo.rowpixels;

                if(_buffer) { free(_buffer); _buffer = NULL; }

                int texformat = PRIMFLAG_GET_TEXFORMAT(prim->flags);
                if(texformat == TEXFORMAT_PALETTE16 || texformat == TEXFORMAT_PALETTEA16)
                {
                    uint32_t *bufferPointer = _buffer = (uint32_t *) malloc(width * height * sizeof(uint32_t));
                    uint16_t *base = (uint16_t *)texinfo.base;
                    for(int y = 0; y < height; ++y)
                    {
                        for(int x = 0; x < width; ++x)
                            *bufferPointer++ = texinfo.palette[*base++];
                        base += rowpixels - width;
                    }

                    rowpixels = width;
                }

                glEnable(GL_TEXTURE_RECTANGLE_EXT);
                glBindTexture(GL_TEXTURE_RECTANGLE_EXT, _texture);
                // Resize if the texture isn't big enough
                if(rowpixels > _textureWidth || height > _textureHeight)
                {
                    _textureWidth  = MAX(rowpixels, _textureWidth);
                    _textureHeight = MAX(height, _textureHeight);

                    glTexImage2D(GL_TEXTURE_RECTANGLE_EXT, 0, GL_RGBA8, _textureWidth, _textureHeight, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, _buffer ?: texinfo.base);
                }
                else
                    glTexSubImage2D(GL_TEXTURE_RECTANGLE_EXT, 0, 0, 0, _buffer ? width : rowpixels, height, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, _buffer ?: texinfo.base);

                GLfloat texCoords[] = { width * prim->texcoords.bl.u, height * prim->texcoords.bl.v,
                                        width * prim->texcoords.tl.u, height * prim->texcoords.tl.v,
                                        width * prim->texcoords.br.u, height * prim->texcoords.br.v,
                                        width * prim->texcoords.tr.u, height * prim->texcoords.tr.v };

                glEnableClientState(GL_TEXTURE_COORD_ARRAY);
                glTexCoordPointer(2, GL_FLOAT, 0, texCoords);
                glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
                glDisableClientState(GL_TEXTURE_COORD_ARRAY);

                glDisable(GL_TEXTURE_RECTANGLE_EXT);
            }
        }
    }
    glFlushRenderAPPLE();

    primitives.release_lock();
}

- (NSTimeInterval)frameInterval
{
    return _frameInterval;
}

#pragma mark - Audio

- (void)osd_update_audio_stream:(const INT16 *)buffer samples:(int)samples_this_frame
{
    OERingBuffer *ringBuffer = [self ringBufferAtIndex:0];
    NSUInteger bytesPerSample = (self.audioBitDepth * self.channelCount) / 8;
    NSUInteger bytesToWrite = samples_this_frame * bytesPerSample;
    NSUInteger bytesAvailableToWrite = ringBuffer.freeBytes;
    
    if(bytesToWrite > bytesAvailableToWrite)
    {
        DLog(@"MAME: Audio buffer overflow");
        bytesToWrite = bytesAvailableToWrite;
    }
    
    [ringBuffer write:buffer maxLength:bytesToWrite];
}

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
    _axes[player-1][0] = _buttons[player-1][OEArcadeButtonLeft] ? INPUT_ABSOLUTE_MIN : (_buttons[player-1][OEArcadeButtonRight] ? INPUT_ABSOLUTE_MAX : 0);
    _axes[player-1][1] = _buttons[player-1][OEArcadeButtonUp] ? INPUT_ABSOLUTE_MIN : (_buttons[player-1][OEArcadeButtonDown] ? INPUT_ABSOLUTE_MAX : 0);
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

static void *_OESaveStateBlock;

static void _OESaveStateCallback(running_machine *machine)
{
    void (^block)(BOOL, NSError *) = (__bridge_transfer void(^)(BOOL, NSError *))_OESaveStateBlock;

    block(YES, nil);
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    _OESaveStateBlock = (__bridge_retained void *)[block copy];
    
    if(_machine != NULL && _machine->system().flags & GAME_SUPPORTS_SAVE)
        _machine->schedule_save([fileName UTF8String]);
    else
    {
        NSLog(@"This game does not support save states!");
        block(NO, nil);
    }
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    _OESaveStateBlock = (__bridge_retained void *)[block copy];

    // Wait until machine is initialized and ready to load a save state
    while(_initializing) usleep(100);

    if(_machine != NULL && _machine->system().flags & GAME_SUPPORTS_SAVE)
        _machine->schedule_load([fileName UTF8String]);
    else
        block(NO, nil);
}

@end
