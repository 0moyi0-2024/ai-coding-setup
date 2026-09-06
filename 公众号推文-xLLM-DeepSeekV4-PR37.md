# DeepSeek V4 首个 PR 代码走读：我用一个 PR 帮你看懂 xLLM 框架

> 一个算子从 C++ 写到 Python 要几步？这篇文章用 DeepSeek V4 的第一个 PR 给你讲透。

最近 DeepSeek V4 热度很高，但很多人好奇：**一个新模型到底是怎么接入推理框架的？** 模型代码写好之后，底层算子怎么对接？C++ 和 Python 怎么分工？

我选了 xLLM 框架上 DeepSeek V4 的首个算子绑定 PR 作为走读对象。读完这篇文章你会搞清楚三件事：

1. xLLM 的整体架构长什么样？每个目录干啥的？
2. PR 37 具体改了什么？为什么需要这些改动？
3. 如果你要在 xLLM 上加一个新算子，完整步骤是什么？

---

## 一、xLLM 是什么？C++ 服务 + Python 模型的双层架构

xLLM 是一个大模型推理框架，采用**双层架构**设计，从上到下分三层：

**第一层：HTTP/gRPC 请求入口**

**第二层：C++ Serving Framework（服务层）**

处理核心调度逻辑：
- api_service → Scheduler → Engine → Worker → Executor
- Tokenizer / Chat Template
- Continuous Batching（连续批处理）
- KV Cache 管理
- PD 分离调度
- 采样 / 投机解码

**第三层：Python Model Execution（模型层）**

- models/（PyCausalLM） ↔ python/models/（nn.Module）
- 模型 forward / logits 计算
- load_weights() 权重加载
- ModelExecutor.forward() 前向执行

**第四层：Kernel / Hardware（算子层）**

- C++ kernels（TORCH_LIBRARY 注册）↔ Python kernels_npu
- AscendC / ACLNN / TileLang 底层实现
- 通过 torch.ops.xllm_ops.* 调用

为什么这么分层？原因很直接：

> **性能敏感的用 C++，迭代频繁的用 Python。**

| 模块 | 语言 | 原因 |
| :--- | :--- | :--- |
| 服务调度、KV Cache、采样 | C++ | 低延迟、零 GIL 开销，生产环境必须快 |
| 模型定义（Attention、MoE） | Python | 新模型迭代快，改 Python 效率高十倍 |
| 底层算子 | C++ + Python | 极致性能用 C++ AscendC，灵活组合用 Python |

社区开发者想接入新模型，只需要写 nn.Module + load_weights()，不用碰 C++ 代码。

---

## 二、目录结构扫盲

xllm/ 目录下主要分为以下几个部分：

**api_service/** — HTTP API 处理层，处理 chat/completions 等接口

**server/** — brpc server 启动与连接管理

**core/** — 核心引擎，包含：

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
| DSA 稀疏注意力 | compressor、sparse_attn_sharedkv 等 | 先选出关键 KV 块，再做两阶段稀疏注意力 |
| HyperConnection | hc_pre、hc_post | 多层特征融合的预处理/后处理 |
| Hash-MoE 路由 | moe_gating_top_k_hash | 用 token ID 哈希替代可学习 gate 选专家 |
| W8A8 融合量化 | dequant_swiglu_quant 等 | RMSNorm/激活函数与 INT8 量化融合 |
| 部分 RoPE | npu_inplace_partial_rotary_mul | 对 Q/K 的部分维度做旋转位置编码 |

这些算子的 C++ AscendC 实现已经写好了，但 **Python 模型层还调不到它们**。PR 37 就是来打通这条路的。

变更概览：**15 个文件，+1794 行**，核心改动四类：

- C++ 算子注册（+86 行）：注册 8 个新算子的 schema 和 NPU 实现
- Python 算子包装（+991 行）：DSA 全链路 + MoE 编排 + FakeTensor 契约
- C++ 桥接重构（+48 行）：Python 模块注册改为惰性初始化
- 测试（+679 行）：C++ 算子探针测试 + Python MoE 编排契约测试

---

## 四、一个算子的完整旅程：从 C++ 到 Python 要走几步？

以 compressor（DSA 的 KV 压缩器）为例，看看一个算子从底层到模型层要经过几道工序。

### 第 1 步：C++ 注册算子 schema

```cpp
TORCH_LIBRARY(xllm_ops, m) {
  m.def("compressor(Tensor x, Tensor wkv, ...)
        -> (Tensor, Tensor, Tensor, Tensor, Tensor)");
}
```

这行代码告诉 PyTorch dispatcher：xllm_ops 命名空间下有个叫 compressor 的算子，接收这些参数，返回 5 个 Tensor。相当于在 PyTorch 的算子注册表里登记了一下。

### 第 2 步：C++ 绑定 NPU 实现

```cpp
TORCH_LIBRARY_IMPL(xllm_ops, PrivateUse1, m) {
  m.impl("compressor", TORCH_FN(xllm::kernel::npu::compressor));
}
```

PrivateUse1 是自定义硬件的 dispatch key（华为 NPU 用的就是它）。当 Tensor 在 NPU 上时，PyTorch 自动把调用路由到这里绑定的 C++ 函数。

### 第 3 步：Python 注册 FakeTensor 契约

```python
def _compressor_fake(x, wkv, wgate, ...):
    # Fake 模式不关心值，只推算输出 shape
    return (x.new_empty(...), ...)

torch.library.register_fake("xllm_ops::compressor", _compressor_fake)
```

**为什么需要 FakeTensor？** 当你用 torch.compile 或者图捕获模式时，PyTorch 并不真的执行算子，它只需要知道"输出长什么样"（shape 和 dtype）。FakeTensor 就是干这个的——形状预言机，不碰真实数据，只推算输出形状。

### 第 4 步：Python 薄包装

```python
def compressor(x, wkv, wgate, kv_state, ...):
    """NSA-style KV pooling compressor."""
    return torch.ops.xllm_ops.compressor(x, wkv, ...)
```

**为啥不直接在模型里调 torch.ops.xllm_ops.compressor？**

- 直接调需要自己处理 NPU 特有的 reshape 细节 → 包装内部做了
- 直接调参数全是位置参数，魔法数字多 → 包装提供具名参数+文档
- NPU 和 CUDA 算子名可能不同 → 包装层做平台分发
- 模型代码耦合底层细节 → 模型层只看高层语义

### 第 5 步：包级导出

在 __init__.py 的导出表里注册后，模型层就能优雅地用了：

```python
from xllm.python import kernels_npu
cmp_kv, wkv_proj, ... = kernels_npu.compressor(x, wkv, ...)
```

**完整调用链路：**

模型层（python/models/deepseek_v4.py）调用 kernels_npu.compressor(...)
→ Python 薄包装（dsa.py）调用 torch.ops.xllm_ops.compressor(...)
→ PyTorch Dispatcher 发现 Tensor 在 NPU 上，路由到 PrivateUse1
→ C++ 实现（compressor.cpp）调用 xllm::kernel::npu::compressor(...)
→ AscendC Kernel（ACLNN / TileLang）在 NPU 芯片上真正执行
→ 结果 Tensor 返回 Python

---

## 五、MoE 编排：不止是薄包装，是 Python 级算子组合

DSA 算子是一对一的薄包装，但 grouped_moe_with_selected_experts 不一样——它在 Python 里**编排了多个底层算子**，实现完整的 MoE 前向：

```python
@torch.library.custom_op("xllm_python::grouped_moe_with_selected_experts", ...)
def grouped_moe_with_selected_experts(hidden_states, ...):
    # ① 路由：按 topk_ids 把 token 分发到对应专家
    expanded_hidden, ... = torch_npu.npu_moe_init_routing_v2(...)
    # ② 动态量化：FP16 → INT8
    sorted_hidden_i8, pertoken_scale = dynamic_quant(expanded_hidden)
    # ③ 第一个 GEMM：w13（gate_proj + up_proj 融合）
    gemm1_out = group_gemm(x=sorted_hidden_i8, weight=w13, ...)
    # ④ 融合算子：反量化 + SwiGLU 激活 + 重新量化
    intermediate_i8, ... = dequant_swiglu_quant(gemm1_out, ...)
    # ⑤ 第二个 GEMM：w2（down_proj）
    gemm2_out = group_gemm(x=intermediate_i8, weight=w2, ...)
    # ⑥ 合并：按原 token 顺序恢复输出
    output = torch_npu.npu_moe_token_unpermute(gemm2_out, ...)
    return output
```

这个函数被注册为 torch.library.custom_op，所以它也能被 torch.compile 追踪和优化。

> 组合逻辑放 Python 是因为 MoE 编排变化快，但每个子算子已经是 C++ 优化过的，性能不受影响。

---

## 六、C++ 侧的重要改动：惰性 Python 模块注册

PR 37 把 py_model_helper.cpp 中的 PYBIND11_EMBEDDED_MODULE 静态注册改成了**惰性初始化**。

改动前：静态注册，Python 初始化时就执行，容易崩。

改动后：惰性注册，第一次用到才创建：

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

**为什么改？** PYBIND11_EMBEDDED_MODULE 在静态初始化阶段执行，如果此时 Python 解释器还没初始化好，直接崩溃。惰性注册确保只在真正需要时才操作 Python 运行时。这个改动虽然只改了 21 行，但解决了一个很头疼的启动顺序问题。

---

## 七、测试怎么写的？

PR 包含两类测试：

**C++ 探针测试**——在真实 NPU 上验证算子数值正确：

```cpp
TEST_F(NpuOpsTest, DsaCompressor) {
  SKIP_IF_NOT_A3();  // 不是 A3 SoC 就跳过
  auto x = torch::randn({1, 16, 128}).to(torch::kPrivateUse1);
  auto [cmp_kv, wkv, ...] = torch::xllm_ops::compressor(...);
  EXPECT_EQ(cmp_kv.sizes(), ...);
  // 与 CPU 参考实现对比数值
}
```

**Python 契约测试**——用 mock 验证编排逻辑，不依赖真实 NPU：

```python
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

完整 Checklist：

1. **C++ 实现算子核心逻辑**
   位置：xllm/core/kernels/npu/xllm_ops/<算子名>.cpp

2. **在 npu_ops_library.cpp 注册 schema**
   TORCH_LIBRARY(xllm_ops, m) { m.def("算子名(Tensor 参数...) -> 返回类型"); }

3. **绑定 NPU 实现**
   TORCH_LIBRARY_IMPL(xllm_ops, PrivateUse1, m) { m.impl("算子名", ...); }

4. **在 npu_ops_api.h 导出声明**（给其他 C++ 文件调用）

5. **注册 FakeTensor 契约**（让 torch.compile 能推断 shape）
   位置：python/kernels_npu/_custom_op.py

6. **写 Python 薄包装**（具名参数 + 文档 + reshape 逻辑）
   位置：按功能放 dsa.py / moe.py / normalization.py

7. **在 __init__.py 的 _EXPORTS 表导出**

8. **写测试**：C++ 数值测试 + Python 编排测试（可选）

9. **新测试文件记得更新 CMakeLists.txt**

新模型接入则是后续 PR 的工作——算子绑定完成后，在 python/models/ 下写模型定义和权重加载，然后注册到模型注册表即可。

---

## 九、几个关键设计决策回顾

| 决策 | 理由 |
| :--- | :--- |
| 算子注册在 C++ 而非 Python | 零开销 dispatch，和 PyTorch 原生算子同等待遇 |
| Python 侧用薄包装 | 屏蔽平台差异、类型提示、方便 mock 测试 |
| FakeTensor 必不可少 | torch.compile / 图捕获不执行真算子，必须有形状预言 |
| MoE 编排放 Python | 组合逻辑变化快，子算子已是 C++，性能无瓶颈 |
| 惰性 Python 模块注册 | 避免静态初始化顺序灾难 |
| C++ 数值测试 + Python mock 测试 | C++ 测正确性，Python 测逻辑，互不依赖 |

---

## 写在最后

PR 37 是 DeepSeek V4 接入 xLLM 的**地基工程**。它干的事情用一句话概括就是：

已有的 AscendC C++ 内核，通过 PR 37 补齐了 TORCH_LIBRARY 注册 → FakeTensor 契约 → Python 薄包装 → 包级导出这条链路，让模型层可以直接调用新算子。后续 PR 会用这些算子组装完整的 DSA + Hash-MoE 前向传播。

理解了这个 PR，你就理解了 xLLM 最核心的设计哲学：**C++ 兜底性能，Python 保证灵活性。** 后续无论加什么新算子、接什么新模型，都是同一个套路。

> 如果这篇文章对你有帮助，欢迎转发给对推理框架感兴趣的朋友。