#import "DoryHVUSBShim.h"

BOOL DoryIOUSBHostSendDeviceRequest(IOUSBHostObject *object,
                                    IOUSBDeviceRequest request,
                                    NSMutableData *data,
                                    NSUInteger *bytesTransferred,
                                    NSTimeInterval timeout,
                                    NSError **error)
{
    return [object sendDeviceRequest:request
                                data:data
                    bytesTransferred:bytesTransferred
                   completionTimeout:timeout
                               error:error];
}

BOOL DoryIOUSBHostAbortDeviceRequests(IOUSBHostObject *object,
                                      IOUSBHostAbortOption option,
                                      NSError **error)
{
    return [object abortDeviceRequestsWithOption:option error:error];
}

BOOL DoryIOUSBHostAbortPipe(IOUSBHostPipe *pipe,
                            IOUSBHostAbortOption option,
                            NSError **error)
{
    return [pipe abortWithOption:option error:error];
}

IOUSBHostDevice *DoryIOUSBHostCreateDevice(io_service_t service,
                                           IOUSBHostObjectInitOptions options,
                                           NSError **error)
{
    return [[IOUSBHostDevice alloc] initWithIOService:service
                                             options:options
                                               queue:nil
                                               error:error
                                     interestHandler:nil];
}

IOUSBHostInterface *DoryIOUSBHostCreateInterface(io_service_t service,
                                                 IOUSBHostObjectInitOptions options,
                                                 NSError **error)
{
    return [[IOUSBHostInterface alloc] initWithIOService:service
                                                options:options
                                                  queue:nil
                                                  error:error
                                        interestHandler:nil];
}

IOUSBHostPipe *DoryIOUSBHostCopyPipe(IOUSBHostInterface *interface,
                                     NSUInteger address,
                                     NSError **error)
{
    return [interface copyPipeWithAddress:address error:error];
}

void DoryIOUSBHostDestroyObject(IOUSBHostObject *object,
                                IOUSBHostObjectDestroyOptions options)
{
    [object destroyWithOptions:options];
}
