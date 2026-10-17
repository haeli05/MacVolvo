/* A windowless GPU render/readback test. No Steam, game or existing prefix is used. */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>

int main(void)
{
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    ID3D11Texture2D *target = NULL, *readback = NULL;
    ID3D11RenderTargetView *view = NULL;
    D3D_FEATURE_LEVEL level;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0,
                                  NULL, 0, D3D11_SDK_VERSION, &device, &level, &context);
    if (FAILED(hr)) { printf("device_failed=%08lx\n", (unsigned long)hr); return 1; }
    D3D11_TEXTURE2D_DESC desc = {0};
    desc.Width = desc.Height = 16;
    desc.MipLevels = desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    hr = ID3D11Device_CreateTexture2D(device, &desc, NULL, &target);
    if (FAILED(hr)) return 2;
    hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)target, NULL, &view);
    if (FAILED(hr)) return 3;
    const float color[4] = {1.0f, 0.0f, 0.0f, 1.0f};
    ID3D11DeviceContext_ClearRenderTargetView(context, view, color);
    desc.BindFlags = 0;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    hr = ID3D11Device_CreateTexture2D(device, &desc, NULL, &readback);
    if (FAILED(hr)) return 4;
    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)readback, (ID3D11Resource *)target);
    D3D11_MAPPED_SUBRESOURCE mapped;
    hr = ID3D11DeviceContext_Map(context, (ID3D11Resource *)readback, 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr)) return 5;
    const unsigned char *pixel = mapped.pData;
    int ok = pixel[0] == 255 && pixel[1] == 0 && pixel[2] == 0 && pixel[3] == 255;
    printf("feature_level=%x pixel=%u,%u,%u,%u result=%s\n", level,
           pixel[0], pixel[1], pixel[2], pixel[3], ok ? "PASS" : "FAIL");
    fflush(stdout);
    ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)readback, 0);
    /* Allow the runner to verify which renderer was actually mapped. */
    Sleep(5000);
    ID3D11RenderTargetView_Release(view);
    ID3D11Texture2D_Release(readback);
    ID3D11Texture2D_Release(target);
    ID3D11DeviceContext_Release(context);
    ID3D11Device_Release(device);
    return ok ? 0 : 6;
}
