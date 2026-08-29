#include "DoryVirglRendererShim.h"

/*
 * Link-only production gate. The build force-loads both reviewed archives around this object so
 * the linker has to close the entire Venus/MoltenVK graph without a Vulkan loader or renderer
 * dylib. The binary is inspected but deliberately not executed; physical GPU evidence belongs to
 * the qualified-VM campaign.
 */
int main(void)
{
    DoryVirglRendererSession *session = NULL;
    return DoryVirglRendererSessionCreate(&session) == INT32_MIN;
}
