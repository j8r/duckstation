// SPDX-FileCopyrightText: 2023 Connor McLaughlin <stenzek@gmail.com>
// SPDX-License-Identifier: (GPL-3.0 OR CC-BY-NC-ND-4.0)

#include "metal_device.h"
#include "spirv_compiler.h"

#include "common/align.h"
#include "common/assert.h"
#include "common/file_system.h"
#include "common/log.h"
#include "common/path.h"
#include "common/string_util.h"

// TODO FIXME...
#define FMT_EXCEPTIONS 0
#include "fmt/format.h"

#include <array>
#include <pthread.h>

Log_SetChannel(MetalDevice);

// TODO: Disable hazard tracking and issue barriers explicitly.

static constexpr MTLPixelFormat LAYER_MTL_PIXEL_FORMAT = MTLPixelFormatRGBA8Unorm;
static constexpr GPUTexture::Format LAYER_TEXTURE_FORMAT = GPUTexture::Format::RGBA8;

// Looking across a range of GPUs, the optimal copy alignment for Vulkan drivers seems
// to be between 1 (AMD/NV) and 64 (Intel). So, we'll go with 64 here.
static constexpr u32 TEXTURE_UPLOAD_ALIGNMENT = 64;

// The pitch alignment must be less or equal to the upload alignment.
// We need 32 here for AVX2, so 64 is also fine.
static constexpr u32 TEXTURE_UPLOAD_PITCH_ALIGNMENT = 64;

static constexpr std::array<MTLPixelFormat, static_cast<u32>(GPUTexture::Format::MaxCount)> s_pixel_format_mapping = {
  MTLPixelFormatInvalid,      // Unknown
  MTLPixelFormatRGBA8Unorm,   // RGBA8
  MTLPixelFormatBGRA8Unorm,   // BGRA8
  MTLPixelFormatB5G6R5Unorm,  // RGB565
  MTLPixelFormatA1BGR5Unorm,  // RGBA5551
  MTLPixelFormatR8Unorm,      // R8
  MTLPixelFormatDepth16Unorm, // D16
  MTLPixelFormatR16Unorm,     // R16
  MTLPixelFormatR16Float,     // R16F
  MTLPixelFormatR32Sint,      // R32I
  MTLPixelFormatR32Uint,      // R32U
  MTLPixelFormatR32Float,     // R32F
  MTLPixelFormatRG8Unorm,     // RG8
  MTLPixelFormatRG16Unorm,    // RG16
  MTLPixelFormatRG16Float,    // RG16F
  MTLPixelFormatRG32Float,    // RG32F
  MTLPixelFormatRGBA16Unorm,  // RGBA16
  MTLPixelFormatRGBA16Float,  // RGBA16F
  MTLPixelFormatRGBA32Float,  // RGBA32F
  MTLPixelFormatBGR10A2Unorm, // RGB10A2
};

static constexpr std::array<float, 4> s_clear_color = {};

static unsigned s_next_bad_shader_id = 1;

static NSString* StringViewToNSString(const std::string_view& str)
{
  if (str.empty())
    return nil;

  return [[[NSString alloc] autorelease] initWithBytes:str.data()
                                                length:static_cast<NSUInteger>(str.length())
                                              encoding:NSUTF8StringEncoding];
}

static void LogNSError(NSError* error, const char* desc, ...)
{
  std::va_list ap;
  va_start(ap, desc);
  Log::Writev("MetalDevice", "", LOGLEVEL_ERROR, desc, ap);
  va_end(ap);

  Log::Writef("MetalDevice", "", LOGLEVEL_ERROR, "  NSError Code: %u", static_cast<u32>(error.code));
  Log::Writef("MetalDevice", "", LOGLEVEL_ERROR, "  NSError Description: %s", [error.description UTF8String]);
}

template<typename F>
static void RunOnMainThread(F&& f)
{
  if ([NSThread isMainThread])
    f();
  else
    dispatch_sync(dispatch_get_main_queue(), f);
}

MetalDevice::MetalDevice() : m_current_viewport(0, 0, 1, 1), m_current_scissor(0, 0, 1, 1)
{
}

MetalDevice::~MetalDevice()
{
  Assert(m_layer == nil);
  Assert(m_device == nil);
}

RenderAPI MetalDevice::GetRenderAPI() const
{
  return RenderAPI::Metal;
}

bool MetalDevice::HasSurface() const
{
  return (m_layer != nil);
}

bool MetalDevice::GetHostRefreshRate(float* refresh_rate)
{
  return GPUDevice::GetHostRefreshRate(refresh_rate);
}

void MetalDevice::SetVSync(bool enabled)
{
  m_vsync_enabled = enabled;

  if (m_layer != nil)
    [m_layer setDisplaySyncEnabled:enabled];
}

bool MetalDevice::CreateDevice(const std::string_view& adapter, bool threaded_presentation)
{
  @autoreleasepool
  {
    id<MTLDevice> device = nil;
    if (!adapter.empty())
    {
      NSArray<id<MTLDevice>>* devices = [MTLCopyAllDevices() autorelease];
      const u32 count = static_cast<u32>([devices count]);
      for (u32 i = 0; i < count; i++)
      {
        if (adapter == [[devices[i] name] UTF8String])
        {
          device = devices[i];
          break;
        }
      }

      if (device == nil)
        Log_ErrorPrint(fmt::format("Failed to find device named '{}'. Trying default.", adapter).c_str());
    }

    if (device == nil)
    {
      device = [MTLCreateSystemDefaultDevice() autorelease];
      if (device == nil)
      {
        Log_ErrorPrint("Failed to create default Metal device.");
        return false;
      }
    }

    id<MTLCommandQueue> queue = [[device newCommandQueue] autorelease];
    if (queue == nil)
    {
      Log_ErrorPrint("Failed to create command queue.");
      return false;
    }

    m_device = [device retain];
    m_queue = [queue retain];
    Log_InfoPrintf("Metal Device: %s", [[m_device name] UTF8String]);

    SetFeatures();

    if (m_window_info.type != WindowInfo::Type::Surfaceless && !CreateLayer())
      return false;

    CreateCommandBuffer();
    RenderBlankFrame();

    if (!CreateBuffers())
    {
      Log_ErrorPrintf("Failed to create buffers.");
      return false;
    }

    return true;
  }
}

void MetalDevice::SetFeatures()
{
  // https://gist.github.com/kylehowells/63d0723abc9588eb734cade4b7df660d
  if ([m_device supportsFamily:MTLGPUFamilyMacCatalyst1] || [m_device supportsFamily:MTLGPUFamilyMac1] ||
      [m_device supportsFamily:MTLGPUFamilyApple3])
  {
    m_max_texture_size = 16384;
  }
  else
  {
    m_max_texture_size = 8192;
  }

  m_max_multisamples = 0;
  for (u32 multisamples = 1; multisamples < 16; multisamples++)
  {
    if (![m_device supportsTextureSampleCount:multisamples])
      break;
    m_max_multisamples = multisamples;
  }

  m_features.dual_source_blend = true;
  m_features.per_sample_shading = true;
  m_features.noperspective_interpolation = true;
  m_features.supports_texture_buffers = true;
  m_features.texture_buffers_emulated_with_ssbo = true;
  m_features.geometry_shaders = false;
  m_features.partial_msaa_resolve = true;
  m_features.shader_cache = true;
  m_features.pipeline_cache = false;
}

void MetalDevice::DestroyDevice()
{
  WaitForPreviousCommandBuffers();

  if (InRenderPass())
    EndRenderPass();

  if (m_upload_cmdbuf != nil)
  {
    [m_upload_encoder endEncoding];
    [m_upload_encoder release];
    m_upload_encoder = nil;
    [m_upload_cmdbuf release];
    m_upload_cmdbuf = nil;
  }
  if (m_render_cmdbuf != nil)
  {
    [m_render_cmdbuf release];
    m_render_cmdbuf = nil;
  }

  DestroyBuffers();

  for (auto& it : m_cleanup_objects)
    [it.second release];
  m_cleanup_objects.clear();

  if (m_queue != nil)
  {
    [m_queue release];
    m_queue = nil;
  }
  if (m_device != nil)
  {
    [m_device release];
    m_device = nil;
  }
}

bool MetalDevice::CreateLayer()
{
  @autoreleasepool
  {
    RunOnMainThread([this]() {
      @autoreleasepool
      {
        Log_InfoPrintf("Creating a %ux%u Metal layer.", m_window_info.surface_width, m_window_info.surface_height);
        const auto size =
          CGSizeMake(static_cast<float>(m_window_info.surface_width), static_cast<float>(m_window_info.surface_height));
        m_layer = [CAMetalLayer layer];
        [m_layer setDevice:m_device];
        [m_layer setDrawableSize:size];
        [m_layer setPixelFormat:MTLPixelFormatRGBA8Unorm];

        NSView* view = GetWindowView();
        [view setWantsLayer:TRUE];
        [view setLayer:m_layer];
      }
    });

    [m_layer setDisplaySyncEnabled:m_vsync_enabled];
    m_window_info.surface_format = GPUTexture::Format::RGBA8;

    DebugAssert(m_layer_pass_desc == nil);
    m_layer_pass_desc = [[MTLRenderPassDescriptor renderPassDescriptor] retain];
    m_layer_pass_desc.renderTargetWidth = m_window_info.surface_width;
    m_layer_pass_desc.renderTargetHeight = m_window_info.surface_height;
    m_layer_pass_desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    m_layer_pass_desc.colorAttachments[0].storeAction = MTLStoreActionStore;
    m_layer_pass_desc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    return true;
  }
}

void MetalDevice::DestroyLayer()
{
  if (m_layer == nil)
    return;

  // Should wait for previous command buffers to finish, which might be rendering to drawables.
  WaitForPreviousCommandBuffers();

  [m_layer_pass_desc release];
  m_layer_pass_desc = nil;
  m_window_info.surface_format = GPUTexture::Format::Unknown;

  RunOnMainThread([this]() {
    NSView* view = GetWindowView();
    [view setLayer:nil];
    [view setWantsLayer:FALSE];
    [m_layer release];
    m_layer = nullptr;
  });
}

void MetalDevice::RenderBlankFrame()
{
  DebugAssert(!InRenderPass());
  if (m_layer == nil)
    return;

  @autoreleasepool
  {
    id<MTLDrawable> drawable = [m_layer nextDrawable];
    m_layer_pass_desc.colorAttachments[0].texture = [drawable texture];
    id<MTLRenderCommandEncoder> encoder = [m_render_cmdbuf renderCommandEncoderWithDescriptor:m_layer_pass_desc];
    [encoder endEncoding];
    [m_render_cmdbuf presentDrawable:drawable];
    SubmitCommandBuffer();
  }
}

bool MetalDevice::UpdateWindow()
{
  if (InRenderPass())
    EndRenderPass();
  DestroyLayer();

  if (!AcquireWindow(false))
    return false;

  if (m_window_info.type != WindowInfo::Type::Surfaceless && !CreateLayer())
  {
    Log_ErrorPrintf("Failed to create layer on updated window");
    return false;
  }

  return true;
}

void MetalDevice::DestroySurface()
{
  DestroyLayer();
}

void MetalDevice::ResizeWindow(s32 new_window_width, s32 new_window_height, float new_window_scale)
{
  @autoreleasepool
  {
    m_window_info.surface_scale = new_window_scale;
    if (static_cast<u32>(new_window_width) == m_window_info.surface_width &&
        static_cast<u32>(new_window_height) == m_window_info.surface_height)
    {
      return;
    }

    m_window_info.surface_width = new_window_width;
    m_window_info.surface_height = new_window_height;

    [m_layer setDrawableSize:CGSizeMake(new_window_width, new_window_height)];
    m_layer_pass_desc.renderTargetWidth = m_window_info.surface_width;
    m_layer_pass_desc.renderTargetHeight = m_window_info.surface_height;
  }
}

std::string MetalDevice::GetDriverInfo() const
{
  @autoreleasepool
  {
    return ([[m_device description] UTF8String]);
  }
}

bool MetalDevice::CreateBuffers()
{
  if (!m_vertex_buffer.Create(m_device, VERTEX_BUFFER_SIZE) || !m_index_buffer.Create(m_device, INDEX_BUFFER_SIZE) ||
      !m_uniform_buffer.Create(m_device, UNIFORM_BUFFER_SIZE) ||
      !m_texture_upload_buffer.Create(m_device, TEXTURE_STREAM_BUFFER_SIZE))
  {
    Log_ErrorPrintf("Failed to create vertex/index/uniform buffers.");
    return false;
  }

  return true;
}

void MetalDevice::DestroyBuffers()
{
  if (m_download_buffer != nil)
  {
    [m_download_buffer release];
    m_download_buffer = nil;
    m_download_buffer_size = 0;
  }

  m_texture_upload_buffer.Destroy();
  m_uniform_buffer.Destroy();
  m_vertex_buffer.Destroy();
  m_index_buffer.Destroy();

  for (auto& it : m_depth_states)
  {
    if (it.second != nil)
      [it.second release];
  }
  m_depth_states.clear();
}

GPUDevice::AdapterAndModeList MetalDevice::StaticGetAdapterAndModeList()
{
  AdapterAndModeList ret;
  @autoreleasepool
  {
    NSArray<id<MTLDevice>>* devices = [MTLCopyAllDevices() autorelease];
    const u32 count = static_cast<u32>([devices count]);
    ret.adapter_names.reserve(count);
    for (u32 i = 0; i < count; i++)
      ret.adapter_names.emplace_back([devices[i].name UTF8String]);
  }

  return ret;
}

GPUDevice::AdapterAndModeList MetalDevice::GetAdapterAndModeList()
{
  return StaticGetAdapterAndModeList();
}

#if 0
bool MetalDevice::CreateTimestampQueries()
{
  for (u32 i = 0; i < NUM_TIMESTAMP_QUERIES; i++)
  {
    for (u32 j = 0; j < 3; j++)
    {
      const CMetal_QUERY_DESC qdesc((j == 0) ? Metal_QUERY_TIMESTAMP_DISJOINT : Metal_QUERY_TIMESTAMP);
      const HRESULT hr = m_device->CreateQuery(&qdesc, m_timestamp_queries[i][j].ReleaseAndGetAddressOf());
      if (FAILED(hr))
      {
        m_timestamp_queries = {};
        return false;
      }
    }
  }

  KickTimestampQuery();
  return true;
}

void MetalDevice::DestroyTimestampQueries()
{
  if (!m_timestamp_queries[0][0])
    return;

  if (m_timestamp_query_started)
    m_context->End(m_timestamp_queries[m_write_timestamp_query][1].Get());

  m_timestamp_queries = {};
  m_read_timestamp_query = 0;
  m_write_timestamp_query = 0;
  m_waiting_timestamp_queries = 0;
  m_timestamp_query_started = 0;
}

void MetalDevice::PopTimestampQuery()
{
  while (m_waiting_timestamp_queries > 0)
  {
    Metal_QUERY_DATA_TIMESTAMP_DISJOINT disjoint;
    const HRESULT disjoint_hr = m_context->GetData(m_timestamp_queries[m_read_timestamp_query][0].Get(), &disjoint,
                                                   sizeof(disjoint), Metal_ASYNC_GETDATA_DONOTFLUSH);
    if (disjoint_hr != S_OK)
      break;

    if (disjoint.Disjoint)
    {
      Log_VerbosePrintf("GPU timing disjoint, resetting.");
      m_read_timestamp_query = 0;
      m_write_timestamp_query = 0;
      m_waiting_timestamp_queries = 0;
      m_timestamp_query_started = 0;
    }
    else
    {
      u64 start = 0, end = 0;
      const HRESULT start_hr = m_context->GetData(m_timestamp_queries[m_read_timestamp_query][1].Get(), &start,
                                                  sizeof(start), Metal_ASYNC_GETDATA_DONOTFLUSH);
      const HRESULT end_hr = m_context->GetData(m_timestamp_queries[m_read_timestamp_query][2].Get(), &end, sizeof(end),
                                                Metal_ASYNC_GETDATA_DONOTFLUSH);
      if (start_hr == S_OK && end_hr == S_OK)
      {
        const float delta =
          static_cast<float>(static_cast<double>(end - start) / (static_cast<double>(disjoint.Frequency) / 1000.0));
        m_accumulated_gpu_time += delta;
        m_read_timestamp_query = (m_read_timestamp_query + 1) % NUM_TIMESTAMP_QUERIES;
        m_waiting_timestamp_queries--;
      }
    }
  }

  if (m_timestamp_query_started)
  {
    m_context->End(m_timestamp_queries[m_write_timestamp_query][2].Get());
    m_context->End(m_timestamp_queries[m_write_timestamp_query][0].Get());
    m_write_timestamp_query = (m_write_timestamp_query + 1) % NUM_TIMESTAMP_QUERIES;
    m_timestamp_query_started = false;
    m_waiting_timestamp_queries++;
  }
}

void MetalDevice::KickTimestampQuery()
{
  if (m_timestamp_query_started || !m_timestamp_queries[0][0] || m_waiting_timestamp_queries == NUM_TIMESTAMP_QUERIES)
    return;

  m_context->Begin(m_timestamp_queries[m_write_timestamp_query][0].Get());
  m_context->End(m_timestamp_queries[m_write_timestamp_query][1].Get());
  m_timestamp_query_started = true;
}
#endif

bool MetalDevice::SetGPUTimingEnabled(bool enabled)
{
#if 0
  if (m_gpu_timing_enabled == enabled)
    return true;

  m_gpu_timing_enabled = enabled;
  if (m_gpu_timing_enabled)
  {
    if (!CreateTimestampQueries())
      return false;

    KickTimestampQuery();
    return true;
  }
  else
  {
    DestroyTimestampQueries();
    return true;
  }
#else
  return false;
#endif
}

float MetalDevice::GetAndResetAccumulatedGPUTime()
{
#if 0
  const float value = m_accumulated_gpu_time;
  m_accumulated_gpu_time = 0.0f;
  return value;
#else
  return 0.0f;
#endif
}

MetalShader::MetalShader(GPUShaderStage stage, id<MTLLibrary> library, id<MTLFunction> function)
  : GPUShader(stage), m_library(library), m_function(function)
{
}

MetalShader::~MetalShader()
{
  MetalDevice::DeferRelease(m_function);
  MetalDevice::DeferRelease(m_library);
}

void MetalShader::SetDebugName(const std::string_view& name)
{
  @autoreleasepool
  {
    [m_function setLabel:StringViewToNSString(name)];
  }
}

// TODO: Clean this up, somehow..
namespace EmuFolders {
extern std::string DataRoot;
}
static void DumpShader(u32 n, const std::string_view& suffix, const std::string_view& data)
{
  if (data.empty())
    return;

  auto fp = FileSystem::OpenManagedCFile(
    Path::Combine(EmuFolders::DataRoot, fmt::format("shader{}_{}.txt", suffix, n)).c_str(), "wb");
  if (!fp)
    return;

  std::fwrite(data.data(), data.length(), 1, fp.get());
}

std::unique_ptr<GPUShader> MetalDevice::CreateShaderFromMSL(GPUShaderStage stage, const std::string_view& source,
                                                            const std::string_view& entry_point)
{
  @autoreleasepool
  {
    NSString* const ns_source = StringViewToNSString(source);
    NSError* error = nullptr;
    id<MTLLibrary> library = [m_device newLibraryWithSource:ns_source options:nil error:&error];
    if (!library)
    {
      LogNSError(error, "Failed to compile %s shader", GPUShader::GetStageName(stage));

      auto fp = FileSystem::OpenManagedCFile(
        Path::Combine(EmuFolders::DataRoot, fmt::format("bad_shader_{}.txt", s_next_bad_shader_id++)).c_str(), "wb");
      if (fp)
      {
        std::fwrite(source.data(), source.size(), 1, fp.get());
        std::fprintf(fp.get(), "\n\nCompile %s failed: %u\n", GPUShader::GetStageName(stage),
                     static_cast<u32>(error.code));

        const char* utf_error = [error.description UTF8String];
        std::fwrite(utf_error, std::strlen(utf_error), 1, fp.get());
      }

      return {};
    }

    id<MTLFunction> function = [library newFunctionWithName:StringViewToNSString(entry_point)];
    if (!function)
    {
      Log_ErrorPrintf("Failed to get main function in compiled library");
      return {};
    }

    return std::unique_ptr<MetalShader>(new MetalShader(stage, [library retain], [function retain]));
  }
}

std::unique_ptr<GPUShader> MetalDevice::CreateShaderFromBinary(GPUShaderStage stage, std::span<const u8> data)
{
  const std::string_view str_data(reinterpret_cast<const char*>(data.data()), data.size());
  return CreateShaderFromMSL(stage, str_data, "main0");
}

std::unique_ptr<GPUShader> MetalDevice::CreateShaderFromSource(GPUShaderStage stage, const std::string_view& source,
                                                               const char* entry_point,
                                                               DynamicHeapArray<u8>* out_binary /* = nullptr */)
{
  const u32 options = (m_debug_device ? SPIRVCompiler::DebugInfo : 0) | SPIRVCompiler::VulkanRules;
  static constexpr bool dump_shaders = false;

  if (std::strcmp(entry_point, "main") != 0)
  {
    Log_ErrorPrintf("Entry point must be 'main', but got '%s' instead.", entry_point);
    return {};
  }

  std::optional<SPIRVCompiler::SPIRVCodeVector> spirv = SPIRVCompiler::CompileShader(stage, source, options);
  if (!spirv.has_value())
  {
    Log_ErrorPrintf("Failed to compile shader to SPIR-V.");
    return {};
  }

  std::optional<std::string> msl = SPIRVCompiler::CompileSPIRVToMSL(spirv.value());
  if (!msl.has_value())
  {
    Log_ErrorPrintf("Failed to compile SPIR-V to MSL.");
    return {};
  }
  if constexpr (dump_shaders)
  {
    DumpShader(s_next_bad_shader_id, "_input", source);
    DumpShader(s_next_bad_shader_id, "_msl", msl.value());
    s_next_bad_shader_id++;
  }

  if (out_binary)
  {
    out_binary->resize(msl->size());
    std::memcpy(out_binary->data(), msl->data(), msl->size());
  }

  return CreateShaderFromMSL(stage, msl.value(), "main0");
}

MetalPipeline::MetalPipeline(id<MTLRenderPipelineState> pipeline, id<MTLDepthStencilState> depth, MTLCullMode cull_mode,
                             MTLPrimitiveType primitive)
  : m_pipeline(pipeline), m_depth(depth), m_cull_mode(cull_mode), m_primitive(primitive)
{
}

MetalPipeline::~MetalPipeline()
{
  MetalDevice::DeferRelease(m_pipeline);
}

void MetalPipeline::SetDebugName(const std::string_view& name)
{
  // readonly property :/
}

id<MTLDepthStencilState> MetalDevice::GetDepthState(const GPUPipeline::DepthState& ds)
{
  const auto it = m_depth_states.find(ds.key);
  if (it != m_depth_states.end())
    return it->second;

  @autoreleasepool
  {
    static constexpr std::array<MTLCompareFunction, static_cast<u32>(GPUPipeline::DepthFunc::MaxCount)> func_mapping = {
      {
        MTLCompareFunctionNever,        // Never
        MTLCompareFunctionAlways,       // Always
        MTLCompareFunctionLess,         // Less
        MTLCompareFunctionLessEqual,    // LessEqual
        MTLCompareFunctionGreater,      // Greater
        MTLCompareFunctionGreaterEqual, // GreaterEqual
        MTLCompareFunctionEqual,        // Equal
      }};

    MTLDepthStencilDescriptor* desc = [[[MTLDepthStencilDescriptor alloc] init] autorelease];
    desc.depthCompareFunction = func_mapping[static_cast<u8>(ds.depth_test.GetValue())];
    desc.depthWriteEnabled = ds.depth_write ? TRUE : FALSE;

    id<MTLDepthStencilState> state = [m_device newDepthStencilStateWithDescriptor:desc];
    m_depth_states.emplace(ds.key, state);
    if (state == nil)
      Log_ErrorPrintf("Failed to create depth-stencil state.");

    return state;
  }
}

std::unique_ptr<GPUPipeline> MetalDevice::CreatePipeline(const GPUPipeline::GraphicsConfig& config)
{
  @autoreleasepool
  {
    static constexpr std::array<MTLPrimitiveTopologyClass, static_cast<u32>(GPUPipeline::Primitive::MaxCount)>
      primitive_classes = {{
        MTLPrimitiveTopologyClassPoint,    // Points
        MTLPrimitiveTopologyClassLine,     // Lines
        MTLPrimitiveTopologyClassTriangle, // Triangles
        MTLPrimitiveTopologyClassTriangle, // TriangleStrips
      }};
    static constexpr std::array<MTLPrimitiveType, static_cast<u32>(GPUPipeline::Primitive::MaxCount)> primitives = {{
      MTLPrimitiveTypePoint,         // Points
      MTLPrimitiveTypeLine,          // Lines
      MTLPrimitiveTypeTriangle,      // Triangles
      MTLPrimitiveTypeTriangleStrip, // TriangleStrips
    }};

    static constexpr u32 MAX_COMPONENTS = 4;
    static constexpr const MTLVertexFormat
      format_mapping[static_cast<u8>(GPUPipeline::VertexAttribute::Type::MaxCount)][MAX_COMPONENTS] = {
        {MTLVertexFormatFloat, MTLVertexFormatFloat2, MTLVertexFormatFloat3, MTLVertexFormatFloat4},     // Float
        {MTLVertexFormatUChar, MTLVertexFormatUChar2, MTLVertexFormatUChar3, MTLVertexFormatUChar4},     // UInt8
        {MTLVertexFormatChar, MTLVertexFormatChar2, MTLVertexFormatChar3, MTLVertexFormatChar4},         // SInt8
        {MTLVertexFormatUCharNormalized, MTLVertexFormatUChar2Normalized, MTLVertexFormatUChar3Normalized,
         MTLVertexFormatUChar4Normalized},                                                               // UNorm8
        {MTLVertexFormatUShort, MTLVertexFormatUShort2, MTLVertexFormatUShort3, MTLVertexFormatUShort4}, // UInt16
        {MTLVertexFormatShort, MTLVertexFormatShort2, MTLVertexFormatShort3, MTLVertexFormatShort4},     // SInt16
        {MTLVertexFormatUShortNormalized, MTLVertexFormatUShort2Normalized, MTLVertexFormatUShort3Normalized,
         MTLVertexFormatUShort4Normalized},                                                              // UNorm16
        {MTLVertexFormatUInt, MTLVertexFormatUInt2, MTLVertexFormatUInt3, MTLVertexFormatUInt4},         // UInt32
        {MTLVertexFormatInt, MTLVertexFormatInt2, MTLVertexFormatInt3, MTLVertexFormatInt4},             // SInt32
      };

    static constexpr std::array<MTLCullMode, static_cast<u32>(GPUPipeline::CullMode::MaxCount)> cull_mapping = {{
      MTLCullModeNone,  // None
      MTLCullModeFront, // Front
      MTLCullModeBack,  // Back
    }};

    static constexpr std::array<MTLBlendFactor, static_cast<u32>(GPUPipeline::BlendFunc::MaxCount)> blend_mapping = {{
      MTLBlendFactorZero,                     // Zero
      MTLBlendFactorOne,                      // One
      MTLBlendFactorSourceColor,              // SrcColor
      MTLBlendFactorOneMinusSourceColor,      // InvSrcColor
      MTLBlendFactorDestinationColor,         // DstColor
      MTLBlendFactorOneMinusDestinationColor, // InvDstColor
      MTLBlendFactorSourceAlpha,              // SrcAlpha
      MTLBlendFactorOneMinusSourceAlpha,      // InvSrcAlpha
      MTLBlendFactorSource1Alpha,             // SrcAlpha1
      MTLBlendFactorOneMinusSource1Alpha,     // InvSrcAlpha1
      MTLBlendFactorDestinationAlpha,         // DstAlpha
      MTLBlendFactorOneMinusDestinationAlpha, // InvDstAlpha
      MTLBlendFactorBlendColor,               // ConstantAlpha
      MTLBlendFactorOneMinusBlendColor,       // InvConstantAlpha
    }};

    static constexpr std::array<MTLBlendOperation, static_cast<u32>(GPUPipeline::BlendOp::MaxCount)> op_mapping = {{
      MTLBlendOperationAdd,             // Add
      MTLBlendOperationSubtract,        // Subtract
      MTLBlendOperationReverseSubtract, // ReverseSubtract
      MTLBlendOperationMin,             // Min
      MTLBlendOperationMax,             // Max
    }};

    MTLRenderPipelineDescriptor* desc = [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
    desc.vertexFunction = static_cast<const MetalShader*>(config.vertex_shader)->GetFunction();
    desc.fragmentFunction = static_cast<const MetalShader*>(config.fragment_shader)->GetFunction();

    desc.colorAttachments[0].pixelFormat = s_pixel_format_mapping[static_cast<u8>(config.color_format)];
    desc.depthAttachmentPixelFormat = s_pixel_format_mapping[static_cast<u8>(config.depth_format)];

    // Input assembly.
    MTLVertexDescriptor* vdesc = nil;
    if (!config.input_layout.vertex_attributes.empty())
    {
      vdesc = [MTLVertexDescriptor vertexDescriptor];
      for (u32 i = 0; i < static_cast<u32>(config.input_layout.vertex_attributes.size()); i++)
      {
        const GPUPipeline::VertexAttribute& va = config.input_layout.vertex_attributes[i];
        DebugAssert(va.components > 0 && va.components <= MAX_COMPONENTS);

        MTLVertexAttributeDescriptor* vd = vdesc.attributes[i];
        vd.format = format_mapping[static_cast<u8>(va.type.GetValue())][va.components - 1];
        vd.offset = static_cast<NSUInteger>(va.offset.GetValue());
        vd.bufferIndex = 1;
      }

      vdesc.layouts[1].stepFunction = MTLVertexStepFunctionPerVertex;
      vdesc.layouts[1].stepRate = 1;
      vdesc.layouts[1].stride = config.input_layout.vertex_stride;

      desc.vertexDescriptor = vdesc;
    }

    // Rasterization state.
    const MTLCullMode cull_mode = cull_mapping[static_cast<u8>(config.rasterization.cull_mode.GetValue())];
    desc.rasterizationEnabled = TRUE;
    desc.inputPrimitiveTopology = primitive_classes[static_cast<u8>(config.primitive)];

    // Depth state
    id<MTLDepthStencilState> depth = GetDepthState(config.depth);
    if (depth == nil)
      return {};

    // Blending state
    MTLRenderPipelineColorAttachmentDescriptor* ca = desc.colorAttachments[0];
    ca.writeMask = (config.blend.write_r ? MTLColorWriteMaskRed : MTLColorWriteMaskNone) |
                   (config.blend.write_g ? MTLColorWriteMaskGreen : MTLColorWriteMaskNone) |
                   (config.blend.write_b ? MTLColorWriteMaskBlue : MTLColorWriteMaskNone) |
                   (config.blend.write_a ? MTLColorWriteMaskAlpha : MTLColorWriteMaskNone);

    // General
    const MTLPrimitiveType primitive = primitives[static_cast<u8>(config.primitive)];
    desc.rasterSampleCount = config.per_sample_shading ? config.samples : 1;

    // Metal-specific stuff
    desc.vertexBuffers[0].mutability = MTLMutabilityImmutable;
    desc.fragmentBuffers[0].mutability = MTLMutabilityImmutable;
    if (!config.input_layout.vertex_attributes.empty())
      desc.vertexBuffers[1].mutability = MTLMutabilityImmutable;
    if (config.layout == GPUPipeline::Layout::SingleTextureBufferAndPushConstants)
      desc.fragmentBuffers[1].mutability = MTLMutabilityImmutable;

    ca.blendingEnabled = config.blend.enable;
    if (config.blend.enable)
    {
      ca.sourceRGBBlendFactor = blend_mapping[static_cast<u8>(config.blend.src_blend.GetValue())];
      ca.destinationRGBBlendFactor = blend_mapping[static_cast<u8>(config.blend.dst_blend.GetValue())];
      ca.rgbBlendOperation = op_mapping[static_cast<u8>(config.blend.blend_op.GetValue())];
      ca.sourceAlphaBlendFactor = blend_mapping[static_cast<u8>(config.blend.src_alpha_blend.GetValue())];
      ca.destinationAlphaBlendFactor = blend_mapping[static_cast<u8>(config.blend.dst_alpha_blend.GetValue())];
      ca.alphaBlendOperation = op_mapping[static_cast<u8>(config.blend.alpha_blend_op.GetValue())];
    }

    NSError* error = nullptr;
    id<MTLRenderPipelineState> pipeline = [m_device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (pipeline == nil)
    {
      LogNSError(error, "Failed to create render pipeline state");
      return {};
    }

    return std::unique_ptr<GPUPipeline>(new MetalPipeline(pipeline, depth, cull_mode, primitive));
  }
}

MetalTexture::MetalTexture(id<MTLTexture> texture, u16 width, u16 height, u8 layers, u8 levels, u8 samples, Type type,
                           Format format)
  : GPUTexture(width, height, layers, levels, samples, type, format), m_texture(texture)
{
}

MetalTexture::~MetalTexture()
{
  MetalDevice::GetInstance().UnbindTexture(this);
  Destroy();
}

bool MetalTexture::IsValid() const
{
  return (m_texture != nil);
}

bool MetalTexture::Update(u32 x, u32 y, u32 width, u32 height, const void* data, u32 pitch, u32 layer /*= 0*/,
                          u32 level /*= 0*/)
{
  const u32 aligned_pitch = Common::AlignUpPow2(width * GetPixelSize(), TEXTURE_UPLOAD_PITCH_ALIGNMENT);
  const u32 req_size = height * aligned_pitch;

  MetalDevice& dev = MetalDevice::GetInstance();
  MetalStreamBuffer& sb = dev.GetTextureStreamBuffer();
  id<MTLBuffer> actual_buffer;
  u32 actual_offset;
  u32 actual_pitch;
  if (req_size >= (sb.GetCurrentSize() / 2u))
  {
    const u32 upload_size = height * pitch;
    const MTLResourceOptions options = MTLResourceStorageModeShared;
    actual_buffer = [dev.GetMTLDevice() newBufferWithBytes:data length:upload_size options:options];
    actual_offset = 0;
    actual_pitch = pitch;
    if (actual_buffer == nil)
    {
      Panic("Failed to allocate temporary buffer.");
      return false;
    }

    dev.DeferRelease(actual_buffer);
  }
  else
  {
    if (!sb.ReserveMemory(req_size, TEXTURE_UPLOAD_ALIGNMENT))
    {
      dev.SubmitCommandBuffer();
      if (!sb.ReserveMemory(req_size, TEXTURE_UPLOAD_ALIGNMENT))
      {
        Panic("Failed to reserve texture upload space.");
        return false;
      }
    }

    actual_offset = sb.GetCurrentOffset();
    StringUtil::StrideMemCpy(sb.GetCurrentHostPointer(), aligned_pitch, data, pitch, width * GetPixelSize(), height);
    sb.CommitMemory(req_size);
    actual_buffer = sb.GetBuffer();
    actual_pitch = aligned_pitch;
  }

  if (m_state == GPUTexture::State::Cleared && (x != 0 || y != 0 || width != m_width || height != m_height))
    dev.CommitClear(this);

  const bool is_inline = (m_use_fence_counter == dev.GetCurrentFenceCounter());

  id<MTLBlitCommandEncoder> encoder = dev.GetBlitEncoder(is_inline);
  [encoder copyFromBuffer:actual_buffer
             sourceOffset:actual_offset
        sourceBytesPerRow:actual_pitch
      sourceBytesPerImage:0
               sourceSize:MTLSizeMake(width, height, 1)
                toTexture:m_texture
         destinationSlice:layer
         destinationLevel:level
        destinationOrigin:MTLOriginMake(x, y, 0)];
  m_state = GPUTexture::State::Dirty;
  return true;
}

bool MetalTexture::Map(void** map, u32* map_stride, u32 x, u32 y, u32 width, u32 height, u32 layer /*= 0*/,
                       u32 level /*= 0*/)
{
  if ((x + width) > GetMipWidth(level) || (y + height) > GetMipHeight(level) || layer > m_layers || level > m_levels)
    return false;

  const u32 aligned_pitch = Common::AlignUpPow2(width * GetPixelSize(), TEXTURE_UPLOAD_PITCH_ALIGNMENT);
  const u32 req_size = height * aligned_pitch;

  MetalDevice& dev = MetalDevice::GetInstance();
  if (m_state == GPUTexture::State::Cleared && (x != 0 || y != 0 || width != m_width || height != m_height))
    dev.CommitClear(this);

  MetalStreamBuffer& sb = dev.GetTextureStreamBuffer();
  if (!sb.ReserveMemory(req_size, TEXTURE_UPLOAD_ALIGNMENT))
  {
    dev.SubmitCommandBuffer();
    if (!sb.ReserveMemory(req_size, TEXTURE_UPLOAD_ALIGNMENT))
    {
      Panic("Failed to allocate space in texture upload buffer");
      return false;
    }
  }

  *map = sb.GetCurrentHostPointer();
  *map_stride = aligned_pitch;
  m_map_x = x;
  m_map_y = y;
  m_map_width = width;
  m_map_height = height;
  m_map_layer = layer;
  m_map_level = level;
  m_state = GPUTexture::State::Dirty;
  return true;
}

void MetalTexture::Unmap()
{
  const u32 aligned_pitch = Common::AlignUpPow2(m_map_width * GetPixelSize(), TEXTURE_UPLOAD_PITCH_ALIGNMENT);
  const u32 req_size = m_map_height * aligned_pitch;

  MetalDevice& dev = MetalDevice::GetInstance();
  MetalStreamBuffer& sb = dev.GetTextureStreamBuffer();
  const u32 offset = sb.GetCurrentOffset();
  sb.CommitMemory(req_size);

  // TODO: track this
  const bool is_inline = true;
  id<MTLBlitCommandEncoder> encoder = dev.GetBlitEncoder(is_inline);
  [encoder copyFromBuffer:sb.GetBuffer()
             sourceOffset:offset
        sourceBytesPerRow:aligned_pitch
      sourceBytesPerImage:0
               sourceSize:MTLSizeMake(m_map_width, m_map_height, 1)
                toTexture:m_texture
         destinationSlice:m_map_layer
         destinationLevel:m_map_level
        destinationOrigin:MTLOriginMake(m_map_x, m_map_y, 0)];

  m_map_x = 0;
  m_map_y = 0;
  m_map_width = 0;
  m_map_height = 0;
  m_map_layer = 0;
  m_map_level = 0;
}

void MetalTexture::MakeReadyForSampling()
{
  MetalDevice::GetInstance().UnbindFramebuffer(this);
}

void MetalTexture::SetDebugName(const std::string_view& name)
{
  @autoreleasepool
  {
    [m_texture setLabel:StringViewToNSString(name)];
  }
}

void MetalTexture::Destroy()
{
  if (m_texture != nil)
  {
    MetalDevice::DeferRelease(m_texture);
    m_texture = nil;
  }
  ClearBaseProperties();
}

std::unique_ptr<GPUTexture> MetalDevice::CreateTexture(u32 width, u32 height, u32 layers, u32 levels, u32 samples,
                                                       GPUTexture::Type type, GPUTexture::Format format,
                                                       const void* data, u32 data_stride, bool dynamic /* = false */)
{
  if (!GPUTexture::ValidateConfig(width, height, layers, layers, samples, type, format))
    return {};

  const MTLPixelFormat pixel_format = s_pixel_format_mapping[static_cast<u8>(format)];
  if (pixel_format == MTLPixelFormatInvalid)
    return {};

  @autoreleasepool
  {
    MTLTextureDescriptor* desc = [[[MTLTextureDescriptor alloc] init] autorelease];
    desc.width = width;
    desc.height = height;
    desc.depth = levels;
    desc.pixelFormat = pixel_format;
    desc.mipmapLevelCount = levels;

    switch (type)
    {
      case GPUTexture::Type::Texture:
        desc.usage = MTLTextureUsageShaderRead;
        break;

      case GPUTexture::Type::RenderTarget:
      case GPUTexture::Type::DepthStencil:
        desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        break;

      case GPUTexture::Type::RWTexture:
        desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        break;

      default:
        UnreachableCode();
        break;
    }

    id<MTLTexture> tex = [m_device newTextureWithDescriptor:desc];
    if (tex == nil)
    {
      Log_ErrorPrintf("Failed to create %ux%u texture.", width, height);
      return {};
    }

    // This one can *definitely* go on the upload buffer.
    std::unique_ptr<GPUTexture> gtex(
      new MetalTexture([tex retain], width, height, layers, levels, samples, type, format));
    if (data)
    {
      // TODO: handle multi-level uploads...
      gtex->Update(0, 0, width, height, data, data_stride, 0, 0);
    }

    return gtex;
  }
}

MetalFramebuffer::MetalFramebuffer(GPUTexture* rt, GPUTexture* ds, u32 width, u32 height, id<MTLTexture> rt_tex,
                                   id<MTLTexture> ds_tex, MTLRenderPassDescriptor* descriptor)
  : GPUFramebuffer(rt, ds, width, height), m_rt_tex(rt_tex), m_ds_tex(ds_tex), m_descriptor(descriptor)
{
}

MetalFramebuffer::~MetalFramebuffer()
{
  // TODO: safe deleting?
  if (m_rt_tex != nil)
    [m_rt_tex release];
  if (m_ds_tex != nil)
    [m_ds_tex release];
  [m_descriptor release];
}

void MetalFramebuffer::SetDebugName(const std::string_view& name)
{
}

MTLRenderPassDescriptor* MetalFramebuffer::GetDescriptor() const
{
  if (m_rt)
  {
    switch (m_rt->GetState())
    {
      case GPUTexture::State::Cleared:
      {
        const auto clear_color = m_rt->GetUNormClearColor();
        m_descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        m_descriptor.colorAttachments[0].clearColor =
          MTLClearColorMake(clear_color[0], clear_color[1], clear_color[2], clear_color[3]);
        m_rt->SetState(GPUTexture::State::Dirty);
      }
      break;

      case GPUTexture::State::Invalidated:
      {
        m_descriptor.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        m_rt->SetState(GPUTexture::State::Dirty);
      }
      break;

      case GPUTexture::State::Dirty:
      {
        m_descriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
      }
      break;

      default:
        UnreachableCode();
        break;
    }
  }

  if (m_ds)
  {
    switch (m_ds->GetState())
    {
      case GPUTexture::State::Cleared:
      {
        m_descriptor.depthAttachment.loadAction = MTLLoadActionClear;
        m_descriptor.depthAttachment.clearDepth = m_ds->GetClearDepth();
        m_ds->SetState(GPUTexture::State::Dirty);
      }
      break;

      case GPUTexture::State::Invalidated:
      {
        m_descriptor.depthAttachment.loadAction = MTLLoadActionDontCare;
        m_ds->SetState(GPUTexture::State::Dirty);
      }
      break;

      case GPUTexture::State::Dirty:
      {
        m_descriptor.depthAttachment.loadAction = MTLLoadActionLoad;
      }
      break;

      default:
        UnreachableCode();
        break;
    }
  }

  return m_descriptor;
}

std::unique_ptr<GPUFramebuffer> MetalDevice::CreateFramebuffer(GPUTexture* rt_or_ds, GPUTexture* ds)
{
  DebugAssert((rt_or_ds || ds) && (!rt_or_ds || rt_or_ds->IsRenderTarget() || (rt_or_ds->IsDepthStencil() && !ds)));
  MetalTexture* RT = static_cast<MetalTexture*>((rt_or_ds && rt_or_ds->IsDepthStencil()) ? nullptr : rt_or_ds);
  MetalTexture* DS = static_cast<MetalTexture*>((rt_or_ds && rt_or_ds->IsDepthStencil()) ? rt_or_ds : ds);

  @autoreleasepool
  {
    MTLRenderPassDescriptor* desc = [[MTLRenderPassDescriptor renderPassDescriptor] retain];
    id<MTLTexture> rt_tex = RT ? [RT->GetMTLTexture() retain] : nil;
    id<MTLTexture> ds_tex = DS ? [DS->GetMTLTexture() retain] : nil;

    if (RT)
    {
      desc.colorAttachments[0].texture = rt_tex;
      desc.colorAttachments[0].loadAction = MTLLoadActionLoad;
      desc.colorAttachments[0].storeAction = MTLStoreActionStore;
    }

    if (DS)
    {
      desc.depthAttachment.texture = ds_tex;
      desc.depthAttachment.loadAction = MTLLoadActionLoad;
      desc.depthAttachment.storeAction = MTLStoreActionStore;
    }

    const u32 width = RT ? RT->GetWidth() : DS->GetWidth();
    const u32 height = RT ? RT->GetHeight() : DS->GetHeight();
    desc.renderTargetWidth = width;
    desc.renderTargetHeight = height;

    return std::unique_ptr<GPUFramebuffer>(new MetalFramebuffer(RT, DS, width, height, rt_tex, ds_tex, desc));
  }
}

MetalSampler::MetalSampler(id<MTLSamplerState> ss) : m_ss(ss)
{
}

MetalSampler::~MetalSampler() = default;

void MetalSampler::SetDebugName(const std::string_view& name)
{
  // lame.. have to put it on the descriptor :/
}

std::unique_ptr<GPUSampler> MetalDevice::CreateSampler(const GPUSampler::Config& config)
{
  @autoreleasepool
  {
    static constexpr std::array<MTLSamplerAddressMode, static_cast<u8>(GPUSampler::AddressMode::MaxCount)> ta = {{
      MTLSamplerAddressModeRepeat,             // Repeat
      MTLSamplerAddressModeClampToEdge,        // ClampToEdge
      MTLSamplerAddressModeClampToBorderColor, // ClampToBorder
    }};
    static constexpr std::array<MTLSamplerMinMagFilter, static_cast<u8>(GPUSampler::Filter::MaxCount)> min_mag_filters =
      {{
        MTLSamplerMinMagFilterNearest, // Nearest
        MTLSamplerMinMagFilterLinear,  // Linear
      }};
    static constexpr std::array<MTLSamplerMipFilter, static_cast<u8>(GPUSampler::Filter::MaxCount)> mip_filters = {{
      MTLSamplerMipFilterNearest, // Nearest
      MTLSamplerMipFilterLinear,  // Linear
    }};

    struct BorderColorMapping
    {
      u32 color;
      MTLSamplerBorderColor mtl_color;
    };
    static constexpr BorderColorMapping border_color_mapping[] = {
      {0x00000000u, MTLSamplerBorderColorTransparentBlack},
      {0xFF000000u, MTLSamplerBorderColorOpaqueBlack},
      {0xFFFFFFFFu, MTLSamplerBorderColorOpaqueWhite},
    };

    MTLSamplerDescriptor* desc = [[[MTLSamplerDescriptor alloc] init] autorelease];
    desc.normalizedCoordinates = true;
    desc.sAddressMode = ta[static_cast<u8>(config.address_u.GetValue())];
    desc.tAddressMode = ta[static_cast<u8>(config.address_v.GetValue())];
    desc.rAddressMode = ta[static_cast<u8>(config.address_w.GetValue())];
    desc.minFilter = min_mag_filters[static_cast<u8>(config.min_filter.GetValue())];
    desc.magFilter = min_mag_filters[static_cast<u8>(config.mag_filter.GetValue())];
    desc.mipFilter = (config.min_lod != config.max_lod) ? mip_filters[static_cast<u8>(config.mip_filter.GetValue())] :
                                                          MTLSamplerMipFilterNotMipmapped;
    desc.lodMinClamp = static_cast<float>(config.min_lod);
    desc.lodMaxClamp = static_cast<float>(config.max_lod);
    desc.maxAnisotropy = config.anisotropy;

    if (config.address_u == GPUSampler::AddressMode::ClampToBorder ||
        config.address_v == GPUSampler::AddressMode::ClampToBorder ||
        config.address_w == GPUSampler::AddressMode::ClampToBorder)
    {
      u32 i;
      for (i = 0; i < static_cast<u32>(std::size(border_color_mapping)); i++)
      {
        if (border_color_mapping[i].color == config.border_color)
          break;
      }
      if (i == std::size(border_color_mapping))
      {
        Log_ErrorPrintf("Unsupported border color: %08X", config.border_color.GetValue());
        return {};
      }

      desc.borderColor = border_color_mapping[i].mtl_color;
    }

    // TODO: Pool?
    id<MTLSamplerState> ss = [m_device newSamplerStateWithDescriptor:desc];
    if (ss == nil)
    {
      Log_ErrorPrintf("Failed to create sampler state.");
      return {};
    }

    return std::unique_ptr<GPUSampler>(new MetalSampler([ss retain]));
  }
}

bool MetalDevice::DownloadTexture(GPUTexture* texture, u32 x, u32 y, u32 width, u32 height, void* out_data,
                                  u32 out_data_stride)
{
  constexpr u32 src_layer = 0;
  constexpr u32 src_level = 0;

  const u32 copy_size = width * texture->GetPixelSize();
  const u32 pitch = Common::AlignUpPow2(copy_size, TEXTURE_UPLOAD_PITCH_ALIGNMENT);
  const u32 required_size = pitch * height;
  if (!CheckDownloadBufferSize(required_size))
    return false;

  MetalTexture* T = static_cast<MetalTexture*>(texture);
  CommitClear(T);

  @autoreleasepool
  {
    id<MTLBlitCommandEncoder> encoder = GetBlitEncoder(true);

    [encoder copyFromTexture:T->GetMTLTexture()
                   sourceSlice:src_layer
                   sourceLevel:src_level
                  sourceOrigin:MTLOriginMake(x, y, 0)
                    sourceSize:MTLSizeMake(width, height, 1)
                      toBuffer:m_download_buffer
             destinationOffset:0
        destinationBytesPerRow:pitch
      destinationBytesPerImage:0];

    SubmitCommandBuffer(true);

    StringUtil::StrideMemCpy(out_data, out_data_stride, [m_download_buffer contents], pitch, copy_size, height);
  }

  return true;
}

bool MetalDevice::CheckDownloadBufferSize(u32 required_size)
{
  if (m_download_buffer_size >= required_size)
    return true;

  @autoreleasepool
  {
    // We don't need to defer releasing this one, it's not going to be used.
    if (m_download_buffer != nil)
      [m_download_buffer release];

    constexpr MTLResourceOptions options = MTLResourceStorageModeShared | MTLResourceOptionCPUCacheModeDefault;
    m_download_buffer = [[m_device newBufferWithLength:required_size options:options] retain];
    if (m_download_buffer == nil)
    {
      Log_ErrorPrintf("Failed to create %u byte download buffer", required_size);
      m_download_buffer_size = 0;
      return false;
    }

    m_download_buffer_size = required_size;
  }

  return true;
}

bool MetalDevice::SupportsTextureFormat(GPUTexture::Format format) const
{
  return (s_pixel_format_mapping[static_cast<u8>(format)] != MTLPixelFormatInvalid);
}

void MetalDevice::CopyTextureRegion(GPUTexture* dst, u32 dst_x, u32 dst_y, u32 dst_layer, u32 dst_level,
                                    GPUTexture* src, u32 src_x, u32 src_y, u32 src_layer, u32 src_level, u32 width,
                                    u32 height)
{
  DebugAssert(src_level < src->GetLevels() && src_layer < src->GetLayers());
  DebugAssert((src_x + width) <= src->GetMipWidth(src_level));
  DebugAssert((src_y + height) <= src->GetMipHeight(src_level));
  DebugAssert(dst_level < dst->GetLevels() && dst_layer < dst->GetLayers());
  DebugAssert((dst_x + width) <= dst->GetMipWidth(dst_level));
  DebugAssert((dst_y + height) <= dst->GetMipHeight(dst_level));

  MetalTexture* D = static_cast<MetalTexture*>(dst);
  MetalTexture* S = static_cast<MetalTexture*>(src);

  if (D->IsRenderTargetOrDepthStencil())
  {
    if (S->GetState() == GPUTexture::State::Cleared)
    {
      if (S->GetWidth() == D->GetWidth() && S->GetHeight() == D->GetHeight())
      {
        // pass clear through
        D->m_state = S->m_state;
        D->m_clear_value = S->m_clear_value;
        return;
      }
    }
    else if (S->GetState() == GPUTexture::State::Invalidated)
    {
      // Contents are undefined ;)
      return;
    }
    else if (dst_x == 0 && dst_y == 0 && width == D->GetMipWidth(dst_level) && height == D->GetMipHeight(dst_level))
    {
      D->SetState(GPUTexture::State::Dirty);
    }

    CommitClear(D);
  }

  CommitClear(S);

  S->SetUseFenceCounter(m_current_fence_counter);
  D->SetUseFenceCounter(m_current_fence_counter);

  @autoreleasepool
  {
    id<MTLBlitCommandEncoder> encoder = GetBlitEncoder(true);
    [encoder copyFromTexture:S->GetMTLTexture()
                 sourceSlice:src_level
                 sourceLevel:src_level
                sourceOrigin:MTLOriginMake(src_x, src_y, 0)
                  sourceSize:MTLSizeMake(width, height, 1)
                   toTexture:D->GetMTLTexture()
            destinationSlice:dst_layer
            destinationLevel:dst_level
           destinationOrigin:MTLOriginMake(dst_x, dst_y, 0)];
  }
}

void MetalDevice::ResolveTextureRegion(GPUTexture* dst, u32 dst_x, u32 dst_y, u32 dst_layer, u32 dst_level,
                                       GPUTexture* src, u32 src_x, u32 src_y, u32 width, u32 height)
{
#if 0
	DebugAssert(src_level < src->GetLevels() && src_layer < src->GetLayers());
	DebugAssert((src_x + width) <= src->GetMipWidth(src_level));
	DebugAssert((src_y + height) <= src->GetMipHeight(src_level));
	DebugAssert(dst_level < dst->GetLevels() && dst_layer < dst->GetLayers());
	DebugAssert((dst_x + width) <= dst->GetMipWidth(dst_level));
	DebugAssert((dst_y + height) <= dst->GetMipHeight(dst_level));
	DebugAssert(!dst->IsMultisampled() && src->IsMultisampled());

	// DX11 can't resolve partial rects.
	Assert(src_x == dst_x && src_y == dst_y);

	MetalTexture* dst11 = static_cast<MetalTexture*>(dst);
	MetalTexture* src11 = static_cast<MetalTexture*>(src);

	src11->CommitClear(m_context.Get());
	dst11->CommitClear(m_context.Get());

	m_context->ResolveSubresource(dst11->GetD3DTexture(), MetalCalcSubresource(dst_level, dst_layer, dst->GetLevels()),
																src11->GetD3DTexture(), MetalCalcSubresource(src_level, src_layer, src->GetLevels()),
																dst11->GetDXGIFormat());
#else
  Panic("Fixme");
#endif
}

void MetalDevice::ClearRenderTarget(GPUTexture* t, u32 c)
{
  GPUDevice::ClearRenderTarget(t, c);
  if (InRenderPass() && m_current_framebuffer && m_current_framebuffer->GetRT() == t)
    EndRenderPass();
}

void MetalDevice::ClearDepth(GPUTexture* t, float d)
{
  GPUDevice::ClearDepth(t, d);
  if (InRenderPass() && m_current_framebuffer && m_current_framebuffer->GetDS() == t)
    EndRenderPass();
}

void MetalDevice::InvalidateRenderTarget(GPUTexture* t)
{
  GPUDevice::InvalidateRenderTarget(t);
  if (InRenderPass() && m_current_framebuffer &&
      (m_current_framebuffer->GetRT() == t || m_current_framebuffer->GetDS() == t))
  {
    EndRenderPass();
  }
}

void MetalDevice::CommitClear(MetalTexture* tex)
{
  if (tex->GetState() == GPUTexture::State::Dirty)
    return;

  DebugAssert(tex->IsRenderTargetOrDepthStencil());

  if (tex->GetState() == GPUTexture::State::Cleared)
  {
    // TODO: We could combine it with the current render pass.
    if (InRenderPass())
      EndRenderPass();

    @autoreleasepool
    {
      // Allocating here seems a bit sad.
      MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
      desc.renderTargetWidth = tex->GetWidth();
      desc.renderTargetHeight = tex->GetHeight();
      if (tex->IsRenderTarget())
      {
        const auto cc = tex->GetUNormClearColor();
        desc.colorAttachments[0].texture = tex->GetMTLTexture();
        desc.colorAttachments[0].loadAction = MTLLoadActionClear;
        desc.colorAttachments[0].storeAction = MTLStoreActionStore;
        desc.colorAttachments[0].clearColor = MTLClearColorMake(cc[0], cc[1], cc[2], cc[3]);
      }
      else
      {
        desc.depthAttachment.texture = tex->GetMTLTexture();
        desc.depthAttachment.loadAction = MTLLoadActionClear;
        desc.depthAttachment.storeAction = MTLStoreActionStore;
        desc.depthAttachment.clearDepth = tex->GetClearDepth();
      }

      id<MTLRenderCommandEncoder> encoder = [m_render_cmdbuf renderCommandEncoderWithDescriptor:desc];
      [encoder endEncoding];
    }
  }
}

MetalTextureBuffer::MetalTextureBuffer(Format format, u32 size_in_elements) : GPUTextureBuffer(format, size_in_elements)
{
}

MetalTextureBuffer::~MetalTextureBuffer()
{
  if (m_buffer.IsValid())
    MetalDevice::GetInstance().UnbindTextureBuffer(this);
  m_buffer.Destroy();
}

bool MetalTextureBuffer::CreateBuffer(id<MTLDevice> device)
{
  return m_buffer.Create(device, GetSizeInBytes());
}

void* MetalTextureBuffer::Map(u32 required_elements)
{
  const u32 esize = GetElementSize(m_format);
  const u32 req_size = esize * required_elements;
  if (!m_buffer.ReserveMemory(req_size, esize))
  {
    MetalDevice::GetInstance().SubmitCommandBufferAndRestartRenderPass("out of space in texture buffer");
    if (!m_buffer.ReserveMemory(req_size, esize))
      Panic("Failed to allocate texture buffer space.");
  }

  m_current_position = m_buffer.GetCurrentOffset() / esize;
  return m_buffer.GetCurrentHostPointer();
}

void MetalTextureBuffer::Unmap(u32 used_elements)
{
  m_buffer.CommitMemory(GetElementSize(m_format) * used_elements);
}

void MetalTextureBuffer::SetDebugName(const std::string_view& name)
{
  @autoreleasepool
  {
    [m_buffer.GetBuffer() setLabel:StringViewToNSString(name)];
  }
}

std::unique_ptr<GPUTextureBuffer> MetalDevice::CreateTextureBuffer(GPUTextureBuffer::Format format,
                                                                   u32 size_in_elements)
{
  std::unique_ptr<MetalTextureBuffer> tb = std::make_unique<MetalTextureBuffer>(format, size_in_elements);
  if (!tb->CreateBuffer(m_device))
    tb.reset();

  return tb;
}

void MetalDevice::PushDebugGroup(const char* fmt, ...)
{
}

void MetalDevice::PopDebugGroup()
{
}

void MetalDevice::InsertDebugMessage(const char* fmt, ...)
{
}

void MetalDevice::MapVertexBuffer(u32 vertex_size, u32 vertex_count, void** map_ptr, u32* map_space,
                                  u32* map_base_vertex)
{
  const u32 req_size = vertex_size * vertex_count;
  if (!m_vertex_buffer.ReserveMemory(req_size, vertex_size))
  {
    SubmitCommandBufferAndRestartRenderPass("out of vertex space");
    if (!m_vertex_buffer.ReserveMemory(req_size, vertex_size))
      Panic("Failed to allocate vertex space");
  }

  *map_ptr = m_vertex_buffer.GetCurrentHostPointer();
  *map_space = m_vertex_buffer.GetCurrentSpace() / vertex_size;
  *map_base_vertex = m_vertex_buffer.GetCurrentOffset() / vertex_size;
}

void MetalDevice::UnmapVertexBuffer(u32 vertex_size, u32 vertex_count)
{
  m_vertex_buffer.CommitMemory(vertex_size * vertex_count);
}

void MetalDevice::MapIndexBuffer(u32 index_count, DrawIndex** map_ptr, u32* map_space, u32* map_base_index)
{
  const u32 req_size = sizeof(DrawIndex) * index_count;
  if (!m_index_buffer.ReserveMemory(req_size, sizeof(DrawIndex)))
  {
    SubmitCommandBufferAndRestartRenderPass("out of index space");
    if (!m_index_buffer.ReserveMemory(req_size, sizeof(DrawIndex)))
      Panic("Failed to allocate index space");
  }

  *map_ptr = reinterpret_cast<DrawIndex*>(m_index_buffer.GetCurrentHostPointer());
  *map_space = m_index_buffer.GetCurrentSpace() / sizeof(DrawIndex);
  *map_base_index = m_index_buffer.GetCurrentOffset() / sizeof(DrawIndex);
}

void MetalDevice::UnmapIndexBuffer(u32 used_index_count)
{
  m_index_buffer.CommitMemory(sizeof(DrawIndex) * used_index_count);
}

void MetalDevice::PushUniformBuffer(const void* data, u32 data_size)
{
  void* map = MapUniformBuffer(data_size);
  std::memcpy(map, data, data_size);
  UnmapUniformBuffer(data_size);
}

void* MetalDevice::MapUniformBuffer(u32 size)
{
  const u32 used_space = Common::AlignUpPow2(size, UNIFORM_BUFFER_ALIGNMENT);
  if (!m_uniform_buffer.ReserveMemory(used_space, UNIFORM_BUFFER_ALIGNMENT))
  {
    SubmitCommandBufferAndRestartRenderPass("out of uniform space");
    if (!m_uniform_buffer.ReserveMemory(used_space, UNIFORM_BUFFER_ALIGNMENT))
      Panic("Failed to allocate uniform space.");
  }

  return m_uniform_buffer.GetCurrentHostPointer();
}

void MetalDevice::UnmapUniformBuffer(u32 size)
{
  m_current_uniform_buffer_position = m_uniform_buffer.GetCurrentOffset();
  m_uniform_buffer.CommitMemory(size);
  if (InRenderPass())
  {
    [m_render_encoder setVertexBufferOffset:m_current_uniform_buffer_position atIndex:0];
    [m_render_encoder setFragmentBufferOffset:m_current_uniform_buffer_position atIndex:0];
  }
}

void MetalDevice::SetFramebuffer(GPUFramebuffer* fb)
{
  if (m_current_framebuffer == fb)
    return;

  if (InRenderPass())
    EndRenderPass();

  m_current_framebuffer = static_cast<MetalFramebuffer*>(fb);

  // Current pipeline might be incompatible, so unbind it.
  // Otherwise it'll get bound to the new render encoder.
  // TODO: we shouldn't need to do this now
  m_current_pipeline = nullptr;
  m_current_depth_state = nil;
}

void MetalDevice::UnbindFramebuffer(MetalFramebuffer* fb)
{
  if (m_current_framebuffer != fb)
    return;

  if (InRenderPass())
    EndRenderPass();
  m_current_framebuffer = nullptr;
}

void MetalDevice::UnbindFramebuffer(MetalTexture* tex)
{
  if (!m_current_framebuffer)
    return;

  if (m_current_framebuffer->GetRT() != tex && m_current_framebuffer->GetDS() != tex)
    return;

  if (InRenderPass())
    EndRenderPass();
  m_current_framebuffer = nullptr;
}

void MetalDevice::SetPipeline(GPUPipeline* pipeline)
{
  DebugAssert(pipeline);
  if (m_current_pipeline == pipeline)
    return;

  m_current_pipeline = static_cast<MetalPipeline*>(pipeline);
  if (InRenderPass())
  {
    [m_render_encoder setRenderPipelineState:m_current_pipeline->GetPipelineState()];

    if (m_current_depth_state != m_current_pipeline->GetDepthState())
    {
      m_current_depth_state = m_current_pipeline->GetDepthState();
      [m_render_encoder setDepthStencilState:m_current_depth_state];
    }
    if (m_current_cull_mode != m_current_pipeline->GetCullMode())
    {
      m_current_cull_mode = m_current_pipeline->GetCullMode();
      [m_render_encoder setCullMode:m_current_cull_mode];
    }
  }
  else
  {
    // Still need to set depth state before the draw begins.
    m_current_depth_state = m_current_pipeline->GetDepthState();
    m_current_cull_mode = m_current_pipeline->GetCullMode();
  }
}

void MetalDevice::UnbindPipeline(MetalPipeline* pl)
{
  if (m_current_pipeline != pl)
    return;

  m_current_pipeline = nullptr;
  m_current_depth_state = nil;
}

void MetalDevice::SetTextureSampler(u32 slot, GPUTexture* texture, GPUSampler* sampler)
{
  DebugAssert(slot < MAX_TEXTURE_SAMPLERS);

  id<MTLTexture> T = texture ? static_cast<MetalTexture*>(texture)->GetMTLTexture() : nil;
  if (texture)
    static_cast<MetalTexture*>(texture)->SetUseFenceCounter(m_current_fence_counter);

  if (m_current_textures[slot] != T)
  {
    m_current_textures[slot] = T;
    if (InRenderPass())
      [m_render_encoder setFragmentTexture:T atIndex:slot];
  }

  id<MTLSamplerState> S = sampler ? static_cast<MetalSampler*>(sampler)->GetSamplerState() : nil;
  if (m_current_samplers[slot] != S)
  {
    m_current_samplers[slot] = S;
    if (InRenderPass())
      [m_render_encoder setFragmentSamplerState:S atIndex:slot];
  }
}

void MetalDevice::SetTextureBuffer(u32 slot, GPUTextureBuffer* buffer)
{
  id<MTLBuffer> B = buffer ? static_cast<MetalTextureBuffer*>(buffer)->GetMTLBuffer() : nil;
  if (m_current_ssbo == B)
    return;

  m_current_ssbo = B;
  if (InRenderPass())
    [m_render_encoder setFragmentBuffer:B offset:0 atIndex:1];
}

void MetalDevice::UnbindTexture(MetalTexture* tex)
{
  const id<MTLTexture> T = tex->GetMTLTexture();
  for (u32 i = 0; i < MAX_TEXTURE_SAMPLERS; i++)
  {
    if (m_current_textures[i] == T)
    {
      m_current_textures[i] = nil;
      if (InRenderPass())
        [m_render_encoder setFragmentTexture:nil atIndex:i];
    }
  }
}

void MetalDevice::UnbindTextureBuffer(MetalTextureBuffer* buf)
{
  if (m_current_ssbo != buf->GetMTLBuffer())
    return;

  m_current_ssbo = nil;
  if (InRenderPass())
    [m_render_encoder setFragmentBuffer:nil offset:0 atIndex:1];
}

void MetalDevice::SetViewport(s32 x, s32 y, s32 width, s32 height)
{
  const Common::Rectangle<s32> new_vp = Common::Rectangle<s32>::FromExtents(x, y, width, height);
  if (new_vp == m_current_viewport)
    return;

  m_current_viewport = new_vp;
  if (InRenderPass())
    SetViewportInRenderEncoder();
}

void MetalDevice::SetScissor(s32 x, s32 y, s32 width, s32 height)
{
  const Common::Rectangle<s32> new_sr = Common::Rectangle<s32>::FromExtents(x, y, width, height);
  if (new_sr == m_current_scissor)
    return;

  m_current_scissor = new_sr;
  if (InRenderPass())
    SetScissorInRenderEncoder();
}

void MetalDevice::BeginRenderPass()
{
  DebugAssert(m_render_encoder == nil);

  // Inline writes :(
  if (m_inline_upload_encoder != nil)
  {
    [m_inline_upload_encoder endEncoding];
    [m_inline_upload_encoder release];
    m_inline_upload_encoder = nil;
  }

  @autoreleasepool
  {
    MTLRenderPassDescriptor* desc;
    if (!m_current_framebuffer)
    {
      // Rendering to view, but we got interrupted...
      desc = [MTLRenderPassDescriptor renderPassDescriptor];
      desc.colorAttachments[0].texture = [m_layer_drawable texture];
      desc.colorAttachments[0].loadAction = MTLLoadActionLoad;
    }
    else
    {
      desc = m_current_framebuffer->GetDescriptor();
      if (MetalTexture* RT = static_cast<MetalTexture*>(m_current_framebuffer->GetRT()))
        RT->SetUseFenceCounter(m_current_fence_counter);
      if (MetalTexture* DS = static_cast<MetalTexture*>(m_current_framebuffer->GetDS()))
        DS->SetUseFenceCounter(m_current_fence_counter);
    }

    m_render_encoder = [[m_render_cmdbuf renderCommandEncoderWithDescriptor:desc] retain];
    SetInitialEncoderState();
  }
}

void MetalDevice::EndRenderPass()
{
  DebugAssert(InRenderPass() && !IsInlineUploading());
  [m_render_encoder endEncoding];
  [m_render_encoder release];
  m_render_encoder = nil;
}

void MetalDevice::EndInlineUploading()
{
  DebugAssert(IsInlineUploading() && !InRenderPass());
  [m_inline_upload_encoder endEncoding];
  [m_inline_upload_encoder release];
  m_inline_upload_encoder = nil;
}

void MetalDevice::EndAnyEncoding()
{
  if (InRenderPass())
    EndRenderPass();
  else if (IsInlineUploading())
    EndInlineUploading();
}

void MetalDevice::SetInitialEncoderState()
{
  // Set initial state.
  // TODO: avoid uniform set here? it's probably going to get changed...
  // Might be better off just deferring all the init until the first draw...
  [m_render_encoder setVertexBuffer:m_uniform_buffer.GetBuffer() offset:m_current_uniform_buffer_position atIndex:0];
  [m_render_encoder setFragmentBuffer:m_uniform_buffer.GetBuffer() offset:m_current_uniform_buffer_position atIndex:0];
  [m_render_encoder setVertexBuffer:m_vertex_buffer.GetBuffer() offset:0 atIndex:1];
  [m_render_encoder setCullMode:m_current_cull_mode];
  if (m_current_depth_state != nil)
    [m_render_encoder setDepthStencilState:m_current_depth_state];
  if (m_current_pipeline != nil)
    [m_render_encoder setRenderPipelineState:m_current_pipeline->GetPipelineState()];
  [m_render_encoder setFragmentTextures:m_current_textures.data() withRange:NSMakeRange(0, MAX_TEXTURE_SAMPLERS)];
  [m_render_encoder setFragmentSamplerStates:m_current_samplers.data() withRange:NSMakeRange(0, MAX_TEXTURE_SAMPLERS)];
  if (m_current_ssbo)
    [m_render_encoder setFragmentBuffer:m_current_ssbo offset:0 atIndex:1];
  SetViewportInRenderEncoder();
  SetScissorInRenderEncoder();
}

void MetalDevice::SetViewportInRenderEncoder()
{
  const Common::Rectangle<s32> rc = ClampToFramebufferSize(m_current_viewport);
  [m_render_encoder
    setViewport:(MTLViewport){static_cast<double>(rc.left), static_cast<double>(rc.top),
                              static_cast<double>(rc.GetWidth()), static_cast<double>(rc.GetHeight()), 0.0, 1.0}];
}

void MetalDevice::SetScissorInRenderEncoder()
{
  const Common::Rectangle<s32> rc = ClampToFramebufferSize(m_current_scissor);
  [m_render_encoder
    setScissorRect:(MTLScissorRect){static_cast<NSUInteger>(rc.left), static_cast<NSUInteger>(rc.top),
                                    static_cast<NSUInteger>(rc.GetWidth()), static_cast<NSUInteger>(rc.GetHeight())}];
}

Common::Rectangle<s32> MetalDevice::ClampToFramebufferSize(const Common::Rectangle<s32>& rc) const
{
  const s32 clamp_width = m_current_framebuffer ? m_current_framebuffer->GetWidth() : m_window_info.surface_width;
  const s32 clamp_height = m_current_framebuffer ? m_current_framebuffer->GetHeight() : m_window_info.surface_height;
  return rc.ClampedSize(clamp_width, clamp_height);
}

void MetalDevice::PreDrawCheck()
{
  if (!InRenderPass())
    BeginRenderPass();
}

void MetalDevice::Draw(u32 vertex_count, u32 base_vertex)
{
  PreDrawCheck();
  [m_render_encoder drawPrimitives:m_current_pipeline->GetPrimitive() vertexStart:base_vertex vertexCount:vertex_count];
}

void MetalDevice::DrawIndexed(u32 index_count, u32 base_index, u32 base_vertex)
{
  PreDrawCheck();

  const u32 index_offset = base_index * sizeof(u16);
  [m_render_encoder drawIndexedPrimitives:m_current_pipeline->GetPrimitive()
                               indexCount:index_count
                                indexType:MTLIndexTypeUInt16
                              indexBuffer:m_index_buffer.GetBuffer()
                        indexBufferOffset:index_offset
                            instanceCount:1
                               baseVertex:base_vertex
                             baseInstance:0];
}

id<MTLBlitCommandEncoder> MetalDevice::GetBlitEncoder(bool is_inline)
{
  @autoreleasepool
  {
    if (!is_inline)
    {
      if (!m_upload_cmdbuf)
      {
        m_upload_cmdbuf = [[m_queue commandBufferWithUnretainedReferences] retain];
        m_upload_encoder = [[m_upload_cmdbuf blitCommandEncoder] retain];
        [m_upload_encoder setLabel:@"Upload Encoder"];
      }
      return m_upload_encoder;
    }

    // Interleaved with draws.
    if (m_inline_upload_encoder != nil)
      return m_inline_upload_encoder;

    if (InRenderPass())
      EndRenderPass();
    m_inline_upload_encoder = [[m_render_cmdbuf blitCommandEncoder] retain];
    return m_inline_upload_encoder;
  }
}

bool MetalDevice::BeginPresent(bool skip_present)
{
  @autoreleasepool
  {
    if (skip_present || m_layer == nil)
      return false;

    EndAnyEncoding();

    m_layer_drawable = [[m_layer nextDrawable] retain];
    if (m_layer_drawable == nil)
      return false;

    SetViewportAndScissor(0, 0, m_window_info.surface_width, m_window_info.surface_height);

    // Set up rendering to layer.
    id<MTLTexture> layer_texture = [m_layer_drawable texture];
    m_current_framebuffer = nullptr;
    m_layer_pass_desc.colorAttachments[0].texture = layer_texture;
    m_layer_pass_desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    m_render_encoder = [[m_render_cmdbuf renderCommandEncoderWithDescriptor:m_layer_pass_desc] retain];
    m_current_pipeline = nullptr;
    m_current_depth_state = nil;
    SetInitialEncoderState();
    return true;
  }
}

void MetalDevice::EndPresent()
{
  DebugAssert(!m_current_framebuffer);
  EndAnyEncoding();

  [m_render_cmdbuf presentDrawable:m_layer_drawable];
  [m_layer_drawable release];
  m_layer_drawable = nil;
  SubmitCommandBuffer();
}

void MetalDevice::CreateCommandBuffer()
{
  @autoreleasepool
  {
    DebugAssert(m_render_cmdbuf == nil);
    const u64 fence_counter = ++m_current_fence_counter;
    m_render_cmdbuf = [[m_queue commandBufferWithUnretainedReferences] retain];
    [m_render_cmdbuf addCompletedHandler:[this, fence_counter](id<MTLCommandBuffer>) {
      CommandBufferCompletedOffThread(fence_counter);
    }];
  }

  CleanupObjects();
}

void MetalDevice::CommandBufferCompletedOffThread(u64 fence_counter)
{
  std::unique_lock lock(m_fence_mutex);
  m_completed_fence_counter.store(std::max(m_completed_fence_counter.load(std::memory_order_acquire), fence_counter),
                                  std::memory_order_release);
}

void MetalDevice::SubmitCommandBuffer(bool wait_for_completion)
{
  if (m_upload_cmdbuf != nil)
  {
    [m_upload_encoder endEncoding];
    [m_upload_encoder release];
    m_upload_encoder = nil;
    [m_upload_cmdbuf commit];
    [m_upload_cmdbuf release];
    m_upload_cmdbuf = nil;
  }

  if (m_render_cmdbuf != nil)
  {
    if (InRenderPass())
      EndRenderPass();
    else if (IsInlineUploading())
      EndInlineUploading();

    [m_render_cmdbuf commit];

    if (wait_for_completion)
      [m_render_cmdbuf waitUntilCompleted];

    [m_render_cmdbuf release];
    m_render_cmdbuf = nil;
  }

  CreateCommandBuffer();
}

void MetalDevice::SubmitCommandBufferAndRestartRenderPass(const char* reason)
{
  Log_DevPrintf("Submitting command buffer and restarting render pass due to %s", reason);

  const bool in_render_pass = InRenderPass();
  SubmitCommandBuffer();
  if (in_render_pass)
    BeginRenderPass();
}

void MetalDevice::WaitForFenceCounter(u64 counter)
{
  if (m_completed_fence_counter.load(std::memory_order_relaxed) >= counter)
    return;

  // TODO: There has to be a better way to do this..
  std::unique_lock lock(m_fence_mutex);
  while (m_completed_fence_counter.load(std::memory_order_acquire) < counter)
  {
    lock.unlock();
    pthread_yield_np();
    lock.lock();
  }

  CleanupObjects();
}

void MetalDevice::WaitForPreviousCommandBuffers()
{
  // Early init?
  if (m_current_fence_counter == 0)
    return;

  WaitForFenceCounter(m_current_fence_counter - 1);
}

void MetalDevice::CleanupObjects()
{
  const u64 counter = m_completed_fence_counter.load(std::memory_order_acquire);
  while (m_cleanup_objects.size() > 0 && m_cleanup_objects.front().first <= counter)
  {
    [m_cleanup_objects.front().second release];
    m_cleanup_objects.pop_front();
  }
}

void MetalDevice::DeferRelease(id obj)
{
  MetalDevice& dev = GetInstance();
  dev.m_cleanup_objects.emplace_back(dev.m_current_fence_counter, obj);
}

void MetalDevice::DeferRelease(u64 fence_counter, id obj)
{
  MetalDevice& dev = GetInstance();
  dev.m_cleanup_objects.emplace_back(fence_counter, obj);
}

std::unique_ptr<GPUDevice> GPUDevice::WrapNewMetalDevice()
{
  return std::unique_ptr<GPUDevice>(new MetalDevice());
}

GPUDevice::AdapterAndModeList GPUDevice::WrapGetMetalAdapterAndModeList()
{
  return MetalDevice::StaticGetAdapterAndModeList();
}
