/* Owned D3D11 window: change size/aspect and recreate buffers as video settings do.
 * No game, Steam account or existing user prefix is opened. */
#define COBJMACROS
#define _WIN32_WINNT 0x0a00
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

static ID3D11Device *device;
static ID3D11DeviceContext *context;
static IDXGISwapChain *swap;
static HWND window;
static unsigned failures;
#define CHECK(call) do { HRESULT hr=(call);if(FAILED(hr)){fprintf(stderr,"line=%d hr=%08lx\n",__LINE__,(unsigned long)hr);return 1;} } while(0)

static void frames(DWORD ms) {
    DWORD start=GetTickCount();
    while(GetTickCount()-start<ms) {
        MSG msg;while(PeekMessageW(&msg,NULL,0,0,PM_REMOVE)){TranslateMessage(&msg);DispatchMessageW(&msg);}
        ID3D11Texture2D *back=NULL;ID3D11RenderTargetView *view=NULL;
        if(SUCCEEDED(IDXGISwapChain_GetBuffer(swap,0,&IID_ID3D11Texture2D,(void **)&back))) {
            if(SUCCEEDED(ID3D11Device_CreateRenderTargetView(device,(ID3D11Resource *)back,NULL,&view))) {
                const float color[]={0.1f,0.3f,0.6f,1};
                ID3D11DeviceContext_ClearRenderTargetView(context,view,color);
                IDXGISwapChain_Present(swap,1,0);ID3D11RenderTargetView_Release(view);
            }
            ID3D11Texture2D_Release(back);
        }
        Sleep(5);
    }
}
static void capture(const char *name,UINT width,UINT height) {
    RECT client;GetClientRect(window,&client);
    DXGI_SWAP_CHAIN_DESC desc={0};IDXGISwapChain_GetDesc(swap,&desc);
    BOOL full=FALSE;IDXGISwapChain_GetFullscreenState(swap,&full,NULL);
    BOOL ok=client.right==(LONG)width && client.bottom==(LONG)height && desc.BufferDesc.Width==width && desc.BufferDesc.Height==height;
    failures+=!ok;
    printf("{\"case\":\"%s\",\"client\":[%ld,%ld],\"buffer\":[%u,%u],\"fullscreen\":%s,\"pass\":%s}\n",name,client.right,client.bottom,desc.BufferDesc.Width,desc.BufferDesc.Height,full?"true":"false",ok?"true":"false");
    fflush(stdout);
}
int main(void) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    RECT rect={0,0,1920,1200};AdjustWindowRect(&rect,WS_OVERLAPPEDWINDOW,FALSE);
    window=CreateWindowExW(0,L"STATIC",L"MacVolvo display-change diagnostic",WS_OVERLAPPEDWINDOW|WS_VISIBLE,
        100,100,rect.right-rect.left,rect.bottom-rect.top,NULL,NULL,NULL,NULL);
    if(!window)return 2;
    DXGI_SWAP_CHAIN_DESC desc={.BufferDesc={.Width=1920,.Height=1200,.Format=DXGI_FORMAT_R8G8B8A8_UNORM},
        .SampleDesc={.Count=1},.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT,.BufferCount=2,
        .OutputWindow=window,.Windowed=TRUE,.SwapEffect=DXGI_SWAP_EFFECT_DISCARD,.Flags=DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH};
    CHECK(D3D11CreateDeviceAndSwapChain(NULL,D3D_DRIVER_TYPE_HARDWARE,NULL,0,NULL,0,D3D11_SDK_VERSION,&desc,&swap,&device,NULL,&context));
    frames(600);capture("windowed",1920,1200);
    CHECK(IDXGISwapChain_SetFullscreenState(swap,TRUE,NULL));
    frames(2200);capture("fullscreen",1920,1200);
    const UINT sizes[][2]={{1280,800},{1440,1080},{1920,1080},{1920,1080},{1920,1200}};
    const char *names[]={"lower-resolution","aspect-4-3","aspect-16-9","same-size-buffers","original-size"};
    for(unsigned i=0;i<5;i++) {
        DXGI_MODE_DESC mode={.Width=sizes[i][0],.Height=sizes[i][1],.Format=DXGI_FORMAT_R8G8B8A8_UNORM};
        CHECK(IDXGISwapChain_ResizeTarget(swap,&mode));
        CHECK(IDXGISwapChain_ResizeBuffers(swap,0,sizes[i][0],sizes[i][1],DXGI_FORMAT_UNKNOWN,desc.Flags));
        frames(900);capture(names[i],sizes[i][0],sizes[i][1]);
    }
    CHECK(IDXGISwapChain_SetFullscreenState(swap,FALSE,NULL));frames(2000);
    CHECK(IDXGISwapChain_SetFullscreenState(swap,TRUE,NULL));frames(2200);capture("fullscreen-again",1920,1200);
    /* Some video-setting changes construct a replacement before releasing the
     * previous swap chain. Both temporarily refer to the same owned window. */
    IDXGISwapChain *previous=swap;IDXGIFactory *factory=NULL;
    CHECK(IDXGISwapChain_GetParent(previous,&IID_IDXGIFactory,(void **)&factory));
    desc.BufferDesc.Width=1280;desc.BufferDesc.Height=800;desc.Windowed=FALSE;
    CHECK(IDXGIFactory_CreateSwapChain(factory,(IUnknown *)device,&desc,&swap));
    IDXGIFactory_Release(factory);frames(1200);capture("replacement-before-release",1280,800);
    IDXGISwapChain_Release(previous);frames(2200);capture("replacement-after-release",1280,800);
    CHECK(IDXGISwapChain_SetFullscreenState(swap,FALSE,NULL));frames(1800);
    IDXGISwapChain_Release(swap);ID3D11DeviceContext_Release(context);ID3D11Device_Release(device);DestroyWindow(window);
    return failures?3:0;
}
