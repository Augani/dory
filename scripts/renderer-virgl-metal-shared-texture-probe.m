#include <stdint.h>
#include <stdio.h>

#include <Metal/Metal.h>

#include "pipe/p_defines.h"
#include "virgl_hw.h"
#include "virglrenderer.h"
#include "vrend/vrend_metal.h"

_Static_assert(VIRGL_RES_BIND_SCANOUT == VIRGL_BIND_SCANOUT,
               "public VirGL scanout bind aliases differ");
_Static_assert(VIRGL_RES_BIND_SCANOUT != PIPE_BIND_SCANOUT,
               "probe no longer distinguishes VirGL and Gallium bind namespaces");

static int channel_is_near(uint8_t actual, uint8_t expected)
{
   const int difference = (int)actual - (int)expected;
   return difference >= -2 && difference <= 2;
}

int main(void)
{
   @autoreleasepool {
      id<MTLDevice> device = MTLCreateSystemDefaultDevice();
      if (!device) {
         fprintf(stderr, "Metal shared-texture probe: no default Metal device\n");
         return 1;
      }

      const struct vrend_metal_texture_description description = {
         .width = 4,
         .height = 4,
         .format = VIRGL_FORMAT_B8G8R8A8_UNORM,
         .bind = VIRGL_RES_BIND_RENDER_TARGET |
            VIRGL_RES_BIND_SAMPLER_VIEW |
            VIRGL_RES_BIND_SCANOUT,
         .usage = PIPE_USAGE_DEFAULT,
      };
      MTLTexture_id opaque_texture = NULL;
      if (!virgl_metal_create_texture(device, &description, &opaque_texture) ||
          !opaque_texture) {
         fprintf(stderr, "Metal shared-texture probe: virgl scanout allocation failed\n");
         return 2;
      }
      id<MTLTexture> texture = (id<MTLTexture>)opaque_texture;
      if (texture.storageMode != MTLStorageModePrivate) {
         fprintf(stderr, "Metal shared-texture probe: scanout is not private storage\n");
         virgl_metal_release_texture(opaque_texture);
         return 3;
      }
      MTLSharedTextureHandle *handle = [texture newSharedTextureHandle];
      if (!handle) {
         fprintf(stderr, "Metal shared-texture probe: scanout has no shared handle\n");
         virgl_metal_release_texture(opaque_texture);
         return 4;
      }
      id<MTLTexture> imported = [device newSharedTextureWithHandle:handle];
      [handle release];
      if (!imported || imported.storageMode != MTLStorageModePrivate ||
          imported.width != 4 || imported.height != 4 ||
          imported.pixelFormat != MTLPixelFormatBGRA8Unorm) {
         fprintf(stderr, "Metal shared-texture probe: shared-handle import differs\n");
         [imported release];
         virgl_metal_release_texture(opaque_texture);
         return 5;
      }

      id<MTLCommandQueue> queue = [device newCommandQueue];
      id<MTLBuffer> readback = [device newBufferWithLength:1024
                                                   options:MTLResourceStorageModeShared];
      id<MTLCommandBuffer> command = [queue commandBuffer];
      MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
      pass.colorAttachments[0].texture = texture;
      pass.colorAttachments[0].loadAction = MTLLoadActionClear;
      pass.colorAttachments[0].storeAction = MTLStoreActionStore;
      pass.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1.0);
      id<MTLRenderCommandEncoder> render = [command renderCommandEncoderWithDescriptor:pass];
      [render endEncoding];
      id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
      [blit copyFromTexture:imported
                sourceSlice:0
                sourceLevel:0
               sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(4, 4, 1)
                   toBuffer:readback
          destinationOffset:0
     destinationBytesPerRow:256
   destinationBytesPerImage:1024];
      [blit endEncoding];
      [command commit];
      [command waitUntilCompleted];

      const uint8_t *pixel = readback.contents;
      const int rendered = command.status == MTLCommandBufferStatusCompleted &&
         channel_is_near(pixel[0], 191) && channel_is_near(pixel[1], 128) &&
         channel_is_near(pixel[2], 64) && channel_is_near(pixel[3], 255);
      [readback release];
      [queue release];
      [imported release];
      virgl_metal_release_texture(opaque_texture);
      if (!rendered) {
         fprintf(stderr, "Metal shared-texture probe: imported render bytes differ\n");
         return 6;
      }
   }
   return 0;
}
