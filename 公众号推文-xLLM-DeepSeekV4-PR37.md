# DeepSeek V4 首个 PR 代码走读：我用一个 PR 帮你看懂 xLLM 框架

> 一个算子从 C++ 写到 Python 要几步？这篇文章用 DeepSeek V4 的第一个 PR 给你讲透。

最近 DeepSeek V4 热度很高，但很多人好奇：**一个新模型到底是怎么接入推理框架的？** 模型代码写好之后，底层算子怎么对接？C++ 和 Python 怎么分工？

我选了 xLLM 框架上 DeepSeek V4 的首个算子绑定 PR 作为走读对象。读完这篇文章你会搞清楚三件事：xLLM 的整体架构长什么样？PR 37 具体改了什么？加一个新算子的完整步骤是什么？

---

## 一、xLLM 是什么？C++ 服务 + Python 模型的双层架构

xLLM 是一个大模型推理框架，采用**双层架构**设计，从上到下分四层：

**HTTP/gRPC 请求入口**
**C++ Serving Framework（服务层）**：api_service → Scheduler → Engine → Worker → Executor；Tokenizer / Chat Template；Continuous Batching；KV Cache 管理；PD 分离调度；采样 / 投机解码
**Python Model Execution（模型层）**：models/（PyCausalLM）↔ python/models/（nn.Module）；模型 forward 计算；load_weights() 权重加载；ModelExecutor.forward() 前向执行
**Kernel / Hardware（算子层）**：C++ kernels（TORCH_LIBRARY 注册）↔ Python kernels_npu；AscendC / ACLNN / TileLang 底层实现；通过 torch.ops.xllm_ops.* 调用

为什么这么分层？核心原则：**性能敏感的用 C++，迭代频繁的用 Python。**

| 模块 | 语言 | 原因 |
| :--- | :--- | :--- |
| 服务调度、KV Cache、采样 | C++ | 低延迟、零 GIL 开销，生产环境必须快 |
| 模型定义（Attention、MoE） | Python | 新模型迭代快，改 Python 效率高十倍 |
| 底层算子 | C++ + Python | 极致性能用 C++ AscendC，灵活组合用 Python |

社区开发者想接入新模型，只需要写 nn.Module + load_weights()，不用碰 C++ 代码。

---

## 二、目录结构扫盲

**api_service/** — HTTP API 处理层（chat/completions 等）
**server/** — brpc server 启动与连接管理
**core/** — 核心引擎：
- scheduler/ — Continuous Batching、PD 分离调度
- runtime/ — Worker、Executor（每步推理引擎）
- distributed_runtime/ — 多机多卡、KV 传输、EP 通信
- framework/ — 执行图编排
- **kernels/** — ⭐ 算子注册与 NPU/CUDA 适配（PR 37 主战场）
- layers/ — C++ 模型层（Attention、MoE、Linear）
- platform/ — 硬件平台抽象（NPU/CUDA/MLU）
- common/ — 公共数据结构（Tensor、StateDict）

**models/** — ⭐ C++ 模型定义与 Python 桥接：
- model_registry.h — 所有模型的注册表
- py_causal_lm.* — C++↔Python 桥接壳
- py_model_helper.* — 嵌入式 Python 基础设施

**python/** — Python 侧代码：
- models/ — Python 模型定义（DeepSeek V4、Qwen3...）
- layers/ — Python 模型层封装
- **kernels_npu/** — ⭐ NPU 算子 Python 包装（PR 37 主战场）
- executor/ — Python ModelExecutor

**processors/** — VLM 图像预处理
**function_call/** — 工具调用解析
**proto/** — 通信协议定义

> ⭐ 标记的是 PR 37 直接改动的地方。

---

## 三、PR 37 做了什么？打通新算子的"最后一公里"

**一句话总结：** 为 DeepSeek V4 的 DSA 稀疏注意力和 Hash-MoE 新算子，建立从 C++ AscendC 内核到 Python 模型层的完整调用链路。

DeepSeek V4 引入了多个全新架构特性，每个都需要对应的算子：

| 新特性 | 需要的算子 | 作用 |
| :--- | :--- | :--- |
| DSA 稀疏注意力 | compressor、sparse_attn_sharedkv 等 | 先选关键 KV 块，再做两阶段稀疏注意力 |
| HyperConnection | hc_pre、hc_post | 多层特征融合的预处理/后处理 |
| Hash-MoE 路由 | moe_gating_top_k_hash | 用 token ID 哈希替代可学习 gate 选专家 |
| W8A8 融合量化 | dequant_swiglu_quant 等 | RMSNorm/激活函数与 INT8 量化融合 |
| 部分 RoPE | npu_inplace_partial_rotary_mul | 对 Q/K 的部分维度做旋转位置编码 |

这些算子的 C++ AscendC 实现已经写好了，但 **Python 模型层还调不到它们**。PR 37 就是来打通这条路的。

变更概览：**15 个文件，+1794 行**，核心改动四类：C++ 算子注册（+86 行，注册 8 个新算子）；Python 算子包装（+991 行，DSA + MoE + FakeTensor）；C++ 桥接重构（+48 行，惰性初始化）；测试（+679 行，C++ + Python）。

---

## 四、一个算子的完整旅程：从 C++ 到 Python 要走几步？

以 compressor（DSA 的 KV 压缩器）为例。

**第 1 步：C++ 注册算子 schema**
```cpp
TORCH_LIBRARY(xllm_ops, m) {
  m.def("compressor(Tensor x, Tensor wkv, ...)
        -> (Tensor, Tensor, Tensor, Tensor, Tensor)");
}
```
告诉 PyTorch dispatcher：xllm_ops 下有个叫 compressor 的算子，接收这些参数，返回 5 个 Tensor。

**第 2 步：C++ 绑定 NPU 实现**
```cpp
TORCH_LIBRARY_IMPL(xllm_ops, PrivateUse1, m) {
  m.impl("compressor", TORCH_FN(xllm::kernel::npu::compressor));
}
```
PrivateUse1 是华为 NPU 的 dispatch key，Tensor 在 NPU 上时自动路由到这个 C++ 函数。

**第 3 步：Python 注册 FakeTensor 契约**
```python
def _compressor_fake(x, wkv, wgate, ...):
    return (x.new_empty(...), ...)  # 只推算 shape，不碰真实数据
torch.library.register_fake("xllm_ops::compressor", _compressor_fake)
```
为什么需要？torch.compile / 图捕获模式不真执行算子，只需要知道输出的 shape 和 dtype。FakeTensor 就是形状预言机。

**第 4 步：Python 薄包装**
```python
def compressor(x, wkv, wgate, kv_state, ...):
    return torch.ops.xllm_ops.compressor(x, wkv, ...)
```
为啥不直接调？薄包装内部处理了 NPU 特有 reshape、提供具名参数、做平台分发、隔离底层细节。

**第 5 步：包级导出**
```python
from xllm.python import kernels_npu
cmp_kv, wkv_proj, ... = kernels_npu.compressor(x, wkv, ...)
```
模型层就能优雅调用了。

**完整调用链路：** 模型层 kernels_npu.compressor(...) → Python 薄包装 torch.ops.xllm_ops.compressor(...) → PyTorch Dispatcher 路由到 PrivateUse1 → C++ compressor.cpp → AscendC Kernel 在 NPU 执行 → 结果返回 Python。

---

## 五、MoE 编排：不止是薄包装，是 Python 级算子组合

DSA 算子是一对一薄包装，但 grouped_moe_with_selected_experts 在 Python 里**编排多个底层算子**，实现完整 MoE 前向：

```python
@torch.library.custom_op("xllm_python::grouped_moe_with_selected_experts", ...)
def grouped_moe_with_selected_experts(hidden_states, ...):
    expanded_hidden, ... = torch_npu.npu_moe_init_routing_v2(...)  # ① 路由分发
    sorted_hidden_i8, pertoken_scale = dynamic_quant(expanded_hidden)  # ② FP16→INT8
    gemm1_out = group_gemm(x=sorted_hidden_i8, weight=w13, ...)  # ③ w13 GEMM
    intermediate_i8, ... = dequant_swiglu_quant(gemm1_out, ...)  # ④ 反量化+SwiGLU+量化
    gemm2_out = group_gemm(x=intermediate_i8, weight=w2, ...)  # ⑤ w2 GEMM
    output = torch_npu.npu_moe_token_unpermute(gemm2_out, ...)  # ⑥ 合并恢复
    return output
```

这个函数注册为 torch.library.custom_op，也能被 torch.compile 追踪优化。组合逻辑放 Python 是因为 MoE 编排变化快，但每个子算子已是 C++ 优化过的，性能不受影响。

---

## 六、C++ 侧重要改动：惰性 Python 模块注册

PR 37 把 PYBIND11_EMBEDDED_MODULE 静态注册改成了**惰性初始化**。改动前：静态注册，Python 未初始化时就执行，容易崩。改动后：第一次用到才创建：

```cpp
void ensure_xllm_weight_loader_module() {
  static bool registered = []() {
    auto mod = py::module_::import("types").attr("ModuleType")("xllm_weight_loader");
    mod.attr("load_tensor") = py::cpp_function(&load_tensor_impl);
    py::module_::import("sys").attr("modules")["xllm_weight_loader"] = mod;
    return true;
  }();
}
```
只改了 21 行，但解决了静态初始化顺序导致的崩溃问题。

---

## 七、测试怎么写的？

两类测试：**C++ 探针测试**（真实 NPU 验证数值）和 **Python 契约测试**（mock 验证编排逻辑，不依赖 NPU）。

```cpp
// C++ 探针测试
TEST_F(NpuOpsTest, DsaCompressor) {
  SKIP_IF_NOT_A3();
  auto x = torch::randn({1, 16, 128}).to(torch::kPrivateUse1);
  auto [cmp_kv, wkv, ...] = torch::xllm_ops::compressor(...);
  EXPECT_EQ(cmp_kv.sizes(), ...);  // 与 CPU 参考实现对比
}
```

```python
# Python 契约测试
def test_grouped_moe_orchestration(monkeypatch):
    calls = []
    monkeypatch.setattr(torch_npu, "npu_moe_init_routing_v2",
                        lambda **kw: calls.append("init_routing") or (...))
    grouped_moe_with_selected_experts(...)
    assert calls == ["init_routing", "quant", "gemm_w13", "swiglu", "gemm_w2", "unpermute"]
```

一个测真数值，一个测调用顺序，互不依赖。

---

## 八、开发者指南：加一个新算子要做什么？

1. C++ 实现算子核心逻辑（xllm/core/kernels/npu/xllm_ops/<算子名>.cpp）
2. 在 npu_ops_library.cpp 注册 schema（TORCH_LIBRARY 里 m.def）
3. 绑定 NPU 实现（TORCH_LIBRARY_IMPL PrivateUse1 里 m.impl）
4. 在 npu_ops_api.h 导出声明
5. 注册 FakeTensor 契约（python/kernels_npu/_custom_op.py）
6. 写 Python 薄包装（具名参数 + 文档 + reshape）
7. 在 __init__.py 的 _EXPORTS 表导出
8. 写测试：C++ 数值测试 + Python 编排测试
9. 新测试文件更新 CMakeLists.txt

新模型接入是后续 PR 的工作——算子绑定完成后，在 python/models/ 下写模型定义和权重加载，注册到模型注册表即可。

---

## 九、关键设计决策回顾

| 决策 | 理由 |
| :--- | :--- |
| 算子注册在 C++ 而非 Python | 零开销 dispatch，和 PyTorch 原生算子同等待遇 |
| Python 侧用薄包装 | 屏蔽平台差异、类型提示、方便 mock 测试 |
| FakeTensor 必不可少 | torch.compile 不执行真算子，必须有形状预言 |
| MoE 编排放 Python | 组合逻辑变化快，子算子已是 C++，性能无瓶颈 |
| 惰性 Python 模块注册 | 避免静态初始化顺序灾难 |
| C++ 数值测试 + Python mock 测试 | C++ 测正确性，Python 测逻辑，互不依赖 |

---

## 写在最后

PR 37 是 DeepSeek V4 接入 xLLM 的**地基工程**。已有的 AscendC C++ 内核，通过 PR 37 补齐了 TORCH_LIBRARY 注册 → FakeTensor 契约 → Python 薄包装 → 包级导出这条链路，让模型层可以直接调用新算子。后续 PR 会用这些算子组装完整的 DSA + Hash-MoE 前向传播。

理解了这个 PR，你就理解了 xLLM 最核心的设计哲学：**C++ 兜底性能，Python 保证灵活性。** 后续无论加什么新算子、接什么新模型，都是同一个套路。

> 如果这篇文章对你有帮助，欢迎转发给对推理框架感兴趣的朋友。