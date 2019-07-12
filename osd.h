#import <Foundation/Foundation.h>
#import "inputenum.h"

#define OE_EXPORTED_CLASS     __attribute__((visibility("default")))

// callback for getting the value of an item on a device
typedef uint32_t (*ItemGetStateFunc)(void *device_internal, void *item_internal);

@class OSD;

@protocol OSDDelegate <NSObject>
- (void)willInitializeWithBounds:(NSSize)bounds fps:(float)fps aspect:(NSSize)aspect;
- (void)updateAudioBuffer:(int16_t const *)buffer samples:(NSInteger)samples;
@end

OE_EXPORTED_CLASS
@interface InputDeviceItem : NSObject
@end

OE_EXPORTED_CLASS
@interface InputDevice : NSObject

@property(nonatomic, readonly) NSUInteger index;
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) NSString *id;

- (InputItemID)addItemNamed:(NSString *)name id:(InputItemID)iid getter:(ItemGetStateFunc)getter context:(void *)context;
@end

OE_EXPORTED_CLASS
@interface InputClass : NSObject
- (InputDevice *)addDeviceNamed:(NSString *)name;
- (InputDevice *)deviceForIndex:(NSUInteger)index;
@end

OE_EXPORTED_CLASS
@interface OSD : NSObject

+ (OSD *)shared;

@property(nonatomic) id <OSDDelegate> delegate;
@property(nonatomic) BOOL verboseOutput;
@property(nonatomic) NSString *romsPath;
@property(nonatomic) NSString *samplesPath;

#pragma make - current game

@property(nonatomic, readonly) InputClass *joystick;
@property(nonatomic, readonly) InputClass *mouse;
@property(nonatomic, readonly) InputClass *keyboard;
@property(nonatomic, readonly) BOOL supportsSave;

/*! name of current driver after calling loadGame:
 * */
@property(nonatomic, readonly) NSString *driverName;

/*! maximum size of render buffer in pixels
 */
@property(nonatomic) NSSize maxBufferSize;

- (BOOL)loadGame:(NSString *)name;
- (BOOL)loadGame:(NSString *)name error:(NSError **)error;
- (void)unload;

#pragma mark - serialization

- (NSData *)serializeState;
- (BOOL)deserializeState:(NSData *)data;

#pragma mark - execution

- (BOOL)execute;
- (void)scheduleSoftReset;
- (void)scheduleHardReset;
- (void)setBuffer:(void *)buffer size:(NSSize)size;

#pragma mark - save / load

@end
