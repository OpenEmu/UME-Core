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

#import <Accelerate/Accelerate.h>

#import <OpenEmuBase/OERingBuffer.h>
#import <OpenGL/gl.h>

#include "emu.h"
#include "emuopts.h"
#include "audit.h"
#include "mame.h"

#include "sdl/sdlsync.h"

#include "osx_osd_interface.h"

@interface MAMEGameCore () <OEArcadeSystemResponderClient> {
    running_machine *_machine;
    render_target *_target;
    INT32 _buttons[OEArcadeButtonCount];
    INT32 _axes[INPUT_MAX_AXIS];
    osd_event *_renderEvent;

    CVOpenGLTextureCacheRef _textureCache;

    NSString *_romDir;
    NSString *_driverName;

    double _sampleRate;
    OEIntSize _bufferSize;
}
@end

static void output_callback(delegate_late_bind *param, const char *format, va_list argptr) {
    NSLog(@"MAME: %@", [[NSString alloc] initWithFormat:[NSString stringWithUTF8String:format] arguments:argptr]);
}

static void mame_did_exit(running_machine *machine) {
    osx_osd_interface &interface = dynamic_cast<osx_osd_interface &>(machine->osd());
    [interface.core() osd_exit:machine];
}

static INT32 joystick_get_state(void *device_internal, void *item_internal) {
    return *(INT32 *)item_internal;
}

@implementation MAMEGameCore

#pragma mark - Lifecycle

+ (void)initialize {
    mame_set_output_channel(OUTPUT_CHANNEL_ERROR, output_delegate(FUNC(output_callback), (delegate_late_bind *)NULL));
    mame_set_output_channel(OUTPUT_CHANNEL_WARNING, output_delegate(FUNC(output_callback), (delegate_late_bind *)NULL));
    mame_set_output_channel(OUTPUT_CHANNEL_INFO, output_delegate(FUNC(output_callback), (delegate_late_bind *)NULL));
    mame_set_output_channel(OUTPUT_CHANNEL_DEBUG, output_delegate(FUNC(output_callback), (delegate_late_bind *)NULL));
    mame_set_output_channel(OUTPUT_CHANNEL_VERBOSE, output_delegate(FUNC(output_callback), (delegate_late_bind *)NULL));
    mame_set_output_channel(OUTPUT_CHANNEL_LOG, output_delegate(FUNC(output_callback), (delegate_late_bind *)NULL));
}

- (id)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _renderEvent = osd_event_alloc(FALSE, FALSE);
    
    // Sensible defaults
    _sampleRate = 48000.0f;
    _bufferSize = (OEIntSize){640, 480};

    return self;
}

- (void)dealloc {
    osd_event_free(_renderEvent);
}

- (void)osd_init:(running_machine *)machine {
    _machine = machine;

    _machine->add_notifier(MACHINE_NOTIFY_EXIT, machine_notify_delegate(FUNC(mame_did_exit), machine));

    _target = _machine->render().target_alloc();
    _target->set_max_update_rate(self.frameInterval);

    INT32 width = 0, height = 0;
    _target->compute_minimum_size(width, height);
    if (width > 0 && height > 0) _bufferSize = OEIntSizeMake(width, height);
    _target->set_bounds(_bufferSize.width, _bufferSize.height);

    // TODO: Fix UI rendering bug
    // This is a temporary fix to disable UI (causes a crash normally)
    render_target *uitarget = _machine->render().target_alloc();
    _target->manager().set_ui_target(*uitarget);

    input_device *input = _machine->input().device_class(DEVICE_CLASS_JOYSTICK).add_device("OpenEmu", NULL);
    input->add_item("X Axis", ITEM_ID_XAXIS, joystick_get_state, &_axes[0]);
    input->add_item("Y Axis", ITEM_ID_YAXIS, joystick_get_state, &_axes[1]);
    input->add_item("Start", ITEM_ID_START, joystick_get_state, &_buttons[OEArcadeButtonP1Start]);
    input->add_item("Select", ITEM_ID_SELECT, joystick_get_state, &_buttons[OEArcadeButtonInsertCoin]);
    input->add_item("Button 1", ITEM_ID_BUTTON1, joystick_get_state, &_buttons[OEArcadeButton1]);
    input->add_item("Button 2", ITEM_ID_BUTTON2, joystick_get_state, &_buttons[OEArcadeButton2]);
    input->add_item("Button 3", ITEM_ID_BUTTON3, joystick_get_state, &_buttons[OEArcadeButton3]);
    input->add_item("Button 4", ITEM_ID_BUTTON4, joystick_get_state, &_buttons[OEArcadeButton4]);
    input->add_item("Button 5", ITEM_ID_BUTTON5, joystick_get_state, &_buttons[OEArcadeButton5]);
    input->add_item("Button 6", ITEM_ID_BUTTON6, joystick_get_state, &_buttons[OEArcadeButton6]);
}

- (void)osd_exit:(running_machine *)machine {
    NSParameterAssert(_machine == machine);

    _machine->render().target_free(_target);
    _target = NULL;

    _machine = NULL;
}

#pragma mark - Execution

- (BOOL)loadFileAtPath:(NSString *)path {

    _romDir = [path stringByDeletingLastPathComponent];
    if (!_romDir) return NO;

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
    while (drivlist.next() && !verified) {
        media_auditor::summary summary = auditor.audit_media(AUDIT_VALIDATE_FAST);
        if (summary == media_auditor::CORRECT) {
            driver = drivlist.driver();
            verified = YES;
        }
    }
    
    return verified;
}

- (void)startEmulation {
    if (!isRunning) {
        [super startEmulation];
        [NSThread detachNewThreadSelector:@selector(mameEmuThread) toTarget:self withObject:nil];
    }
}

- (void)stopEmulation {
    // For some reason, this does not work yet, the game thread does not exit
    if (_machine != NULL) _machine->schedule_exit();
    [super stopEmulation];
}

- (void)setPauseEmulation:(BOOL)pauseEmulation {
    if (_machine != NULL) {
        if (pauseEmulation) _machine->pause();
        else _machine->resume();
    }

    [super setPauseEmulation:pauseEmulation];
}

- (void)resetEmulation {
    if (_machine != NULL) _machine->schedule_hard_reset();
}

- (void)mameEmuThread {
    astring err;

    emu_options options = emu_options();
    options.set_value(OPTION_SAMPLERATE, (int)_sampleRate, OPTION_PRIORITY_HIGH, err);
    options.set_value(OPTION_MEDIAPATH, [_romDir UTF8String], OPTION_PRIORITY_HIGH, err);
    options.set_value(OPTION_SYSTEMNAME, [_driverName UTF8String], OPTION_PRIORITY_HIGH, err);
#ifdef DEBUG
    options.set_value(OPTION_VERBOSE, true, OPTION_PRIORITY_HIGH, err);
#endif

    osx_osd_interface interface = osx_osd_interface(self);

    NSLog(@"MAME: Starting game execution thread");
    
    mame_execute(options, interface);

    NSLog(@"MAME: Game execution thread exiting");
}

#pragma mark - Video

- (BOOL)rendersToOpenGL {
    return YES;
}

- (OEIntSize)bufferSize {
    return _bufferSize;
}

- (OEIntSize)aspectSize {
    return _bufferSize;
}

- (void)osd_update:(bool)skip_redraw {
    osd_event_set(_renderEvent);
}

- (void)executeFrameSkippingFrame:(BOOL)skip {
    if (skip || _target == NULL) return;

    // Only wait for 5 frames or so maximum
    int status = osd_event_wait(_renderEvent, 5 * (osd_ticks_per_second() / self.frameInterval));
    if (status == FALSE) return;

    render_primitive_list &primitives = _target->get_primitives();
    primitives.acquire_lock();
    
    if (_textureCache == NULL) {
        CGLContextObj context = CGLGetCurrentContext();
        CVOpenGLTextureCacheCreate(NULL, NULL, context, CGLGetPixelFormat(context), NULL, &_textureCache);
    }

    glShadeModel(GL_SMOOTH);

    glHint(GL_PERSPECTIVE_CORRECTION_HINT, GL_NICEST);
    glDisable(GL_DEPTH_TEST);
    glClearDepth(1.0f);
    glClear(GL_DEPTH_BUFFER_BIT);

    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    glDisable(GL_LINE_SMOOTH);
    glDisable(GL_POINT_SMOOTH);

    glViewport(0.0, 0.0, (GLsizei)_bufferSize.width, (GLsizei)_bufferSize.height);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0.0, (GLdouble)_bufferSize.width, (GLdouble)_bufferSize.height, 0.0, 0.0, -1.0);

    for (render_primitive *prim = primitives.first(); prim != NULL; prim = prim->next()) {
        GLfloat color[4];
        color[0] = prim->color.r;
        color[1] = prim->color.g;
        color[2] = prim->color.b;
        color[3] = prim->color.a;

        switch (PRIMFLAG_GET_BLENDMODE(prim->flags)) {
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

        switch (prim->type) {
            case render_primitive::LINE: {
                BOOL line = ((prim->bounds.x1 != prim->bounds.x0) || (prim->bounds.y1 != prim->bounds.y0));
                if (line) glLineWidth(prim->width);
                else glPointSize(prim->width);

                glBegin(line ? GL_LINES : GL_POINTS);
                glColor4fv(color);
                glVertex2f(prim->bounds.x0, prim->bounds.y0);
                if (line) glVertex2f(prim->bounds.x1, prim->bounds.y1);
                glEnd();

                break;
            }

            case render_primitive::QUAD: {
                if (prim->texture.base == NULL) {
                    glLineWidth(1.0f);
                    glPointSize(1.0f);
                    glBegin(GL_QUADS);
                    glColor4fv(color);
                    glVertex2f(prim->bounds.x0, prim->bounds.y0);
                    glColor4fv(color);
                    glVertex2f(prim->bounds.x1, prim->bounds.y0);
                    glColor4fv(color);
                    glVertex2f(prim->bounds.x1, prim->bounds.y1);
                    glColor4fv(color);
                    glVertex2f(prim->bounds.x0, prim->bounds.y1);
                    glEnd();
                } else {
                    render_texinfo texinfo = prim->texture;
                    size_t width = texinfo.width, height = texinfo.height;
                    CVPixelBufferRef pixelBuffer = NULL;
                    CVPixelBufferCreate(NULL, width, height, k32ARGBPixelFormat, NULL, &pixelBuffer);

                    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
                    uint32_t *buffer = (uint32_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
                    int texformat = PRIMFLAG_GET_TEXFORMAT(prim->flags);
                    switch (texformat) {
                        case TEXFORMAT_PALETTE16:
                        case TEXFORMAT_PALETTEA16: {
                            uint16_t *base = (uint16_t *)texinfo.base;
                            for (int y = 0; y < height; y++) {
                                for (int x = 0; x < width; x++) {
                                    *buffer++ = texinfo.palette[*base++];
                                }
                                base += texinfo.rowpixels - width;
                            }

                            break;
                        }
                        case TEXFORMAT_RGB32:
                        case TEXFORMAT_ARGB32: {
                            rgb_t *base = (rgb_t *)texinfo.base;
                            for (int y = 0; y < height; y++) {
                                for (int x = 0; x < width; x++) {
                                    *buffer++ = *base++;
                                }
                                base += texinfo.rowpixels - width;
                            }

                            break;
                        }

                        default:
                            break;
                    }

                    /*if (texformat == TEXFORMAT_RGB32 || texformat == TEXFORMAT_PALETTE16) {
                        vImage_Buffer image = { buffer, height, width, CVPixelBufferGetBytesPerRow(pixelBuffer) };
                        Pixel_8888 solidColor = { 0xFF, 0xFF, 0xFF, 0xFF };
                        vImageOverwriteChannelsWithPixel_ARGB8888(solidColor, &image, &image, 0x8, kvImage);
                    }*/

                    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

                    CVOpenGLTextureRef texture = NULL;
                    CVOpenGLTextureCacheCreateTextureFromImage(NULL, _textureCache, pixelBuffer, NULL, &texture);

                    GLenum target = CVOpenGLTextureGetTarget(texture);
                    glEnable(target);
                    glBindTexture(target, CVOpenGLTextureGetName(texture));

                    glBegin(GL_QUADS);
                    glColor4fv(color);
                    glTexCoord2f(width * prim->texcoords.tl.u, height * prim->texcoords.tl.v);
                    glVertex2f(prim->bounds.x0, prim->bounds.y0);
                    glColor4fv(color);
                    glTexCoord2f(width * prim->texcoords.tr.u, height * prim->texcoords.tr.v);
                    glVertex2f(prim->bounds.x1, prim->bounds.y0);
                    glColor4fv(color);
                    glTexCoord2f(width * prim->texcoords.br.u, height * prim->texcoords.br.v);
                    glVertex2f(prim->bounds.x1, prim->bounds.y1);
                    glColor4fv(color);
                    glTexCoord2f(width * prim->texcoords.bl.u, height * prim->texcoords.bl.v);
                    glVertex2f(prim->bounds.x0, prim->bounds.y1);
                    glEnd();

                    glDisable(target);

                    CVOpenGLTextureRelease(texture);
                    CVPixelBufferRelease(pixelBuffer);
                }

                break;
            }

            default:
                break;
        }
    }

    primitives.release_lock();
}

- (void)executeFrame {
    [self executeFrameSkippingFrame:NO];
}

#pragma mark - Audio

- (void)osd_update_audio_stream:(const INT16 *)buffer samples:(int)samples_this_frame {
    OERingBuffer *ringBuffer = [self ringBufferAtIndex:0];
    NSUInteger bytesPerFrame = (self.audioBitDepth * self.channelCount) / 8;
    NSUInteger bytesToWrite = samples_this_frame * bytesPerFrame;
    NSUInteger bytesAvailableToWrite = ringBuffer.availableBytes;
    
    if (bytesToWrite > bytesAvailableToWrite) {
        NSLog(@"MAME: Audio buffer overflow");
        bytesToWrite = bytesAvailableToWrite;
    }
    
    [ringBuffer write:buffer maxLength:bytesToWrite];
}

- (double)audioSampleRate {
    return _sampleRate;
}

- (NSUInteger)channelCount {
    return 2;
}

#pragma mark - Input

- (void)setState:(BOOL)pressed ofButton:(OEArcadeButton)button forPlayer:(NSUInteger)player {
    _buttons[button] = pressed ? 1 : 0;
    _axes[0] = _buttons[OEArcadeButtonLeft] ? INPUT_ABSOLUTE_MIN : (_buttons[OEArcadeButtonRight] ? INPUT_ABSOLUTE_MAX : 0);
    _axes[1] = _buttons[OEArcadeButtonUp] ? INPUT_ABSOLUTE_MIN : (_buttons[OEArcadeButtonDown] ? INPUT_ABSOLUTE_MAX : 0);
}

- (oneway void)didPushArcadeButton:(OEArcadeButton)button forPlayer:(NSUInteger)player {
    [self setState:YES ofButton:button forPlayer:player];
}

- (oneway void)didReleaseArcadeButton:(OEArcadeButton)button forPlayer:(NSUInteger)player {
    [self setState:NO ofButton:button forPlayer:player];
}

#pragma mark - Save State

// Both loading and saving state is broken, crashes

- (BOOL)saveStateToFileAtPath:(NSString *)fileName {
    if (_machine != NULL) _machine->schedule_save([fileName UTF8String]);
    return (_machine != NULL);
}

- (BOOL)loadStateFromFileAtPath:(NSString *)fileName {
    if (_machine != NULL) _machine->schedule_load([fileName UTF8String]);
    return (_machine != NULL);
}

@end
