#import <Foundation/Foundation.h>
#import <IOKit/usb/USB.h>
#import <IOUSBHost/IOUSBHost.h>

NS_ASSUME_NONNULL_BEGIN

BOOL DoryIOUSBHostSendDeviceRequest(IOUSBHostObject *object,
                                    IOUSBDeviceRequest request,
                                    NSMutableData *_Nullable data,
                                    NSUInteger *_Nullable bytesTransferred,
                                    NSTimeInterval timeout,
                                    NSError *_Nullable *_Nullable error);

BOOL DoryIOUSBHostAbortDeviceRequests(IOUSBHostObject *object,
                                      IOUSBHostAbortOption option,
                                      NSError *_Nullable *_Nullable error);

BOOL DoryIOUSBHostAbortPipe(IOUSBHostPipe *pipe,
                            IOUSBHostAbortOption option,
                            NSError *_Nullable *_Nullable error);

IOUSBHostDevice *_Nullable DoryIOUSBHostCreateDevice(io_service_t service,
                                                     IOUSBHostObjectInitOptions options,
                                                     NSError *_Nullable *_Nullable error);

IOUSBHostInterface *_Nullable DoryIOUSBHostCreateInterface(io_service_t service,
                                                           IOUSBHostObjectInitOptions options,
                                                           NSError *_Nullable *_Nullable error);

IOUSBHostPipe *_Nullable DoryIOUSBHostCopyPipe(IOUSBHostInterface *interface,
                                               NSUInteger address,
                                               NSError *_Nullable *_Nullable error);

void DoryIOUSBHostDestroyObject(IOUSBHostObject *object,
                                IOUSBHostObjectDestroyOptions options);

NS_ASSUME_NONNULL_END
