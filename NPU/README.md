# NPU：模型部署、算子开发与集合通信

五个阶段分别存放于 `phase1` 至 `phase5` 目录，每个阶段使用独立的 README。名词解释统一见 [名词与缩写](../glossary/README.md)。

| 阶段 | 任务文档 | 核心产物 |
| --- | --- | --- |
| Phase 1 | [架构、环境与单卡验证](phase1/README.md) | 兼容性清单、设备映射、计算正确性日志 |
| Phase 2 | [模型转换与离线推理](phase2/README.md) | ONNX/OM、输入输出规范、推理程序与精度对比 |
| Phase 3 | [精度、吞吐与性能定位](phase3/README.md) | 固定负载矩阵、时间线、优化前后报告 |
| Phase 4 | [Ascend C 算子开发与调优](phase4/README.md) | 自定义算子、边界测试、tiling 对照 |
| Phase 5 | [多卡、跨节点通信与训练](phase5/README.md) | HCCL 正确性、扩展效率、训练恢复记录 |

## 1. 范围与路线

NPU 指神经网络处理单元，不指网络处理器。采用昇腾 Ascend 的 CANN、AscendCL、torch_npu、Ascend C、HCCL 作为操作主线；Intel 客户端 NPU、其他厂商推理卡不能直接套用本路线的驱动、API 或训练能力。

推理任务可在支持相应模型和工具链的 Ascend 310/310P 系列执行；torch_npu、Ascend C、多卡训练及通信任务以支持对应能力的 Ascend 910 系列具体产品为条件。系列名称不是兼容性保证，必须核对实际 SoC、板卡、主机架构、固件、驱动与软件版本。不要求为了完成清单在不支持的推理设备上运行训练。

**执行边界：**文档给出操作方法和判定标准，硬件测试均待执行。缺少适配设备、算子工具链、第二张卡或第二节点时记录限制，不用 CPU 模拟、GPU 数据或理论算力替代 NPU 实测。模型编译成功也不等于推理正确或已经运行在 NPU。

### 1.1 硬件与软件基线

| 项目 | 要求 | 选择原因 |
| --- | --- | --- |
| 主机 | 产品支持的 Linux 与 x86_64/aarch64 主机；按部署指南规划 CPU、内存、磁盘 | NPU 驱动安装包与工具链可能区分主机架构 |
| NPU | 单卡起步；多卡/训练任务需具备对应能力的设备；记录板卡与芯片编号 | 板卡、芯片、逻辑设备和 rank 编号不能混用 |
| 网络 | 两节点管理网与数据网分离；跨节点需受产品支持的设备网络及交换网络 | HCCL 的数据面不能照搬 NCCL 的网卡参数 |
| 驱动/固件 | 依实际 SKU 的官方兼容表配套安装 | 不按“最新”拼接，保留原版本及恢复方式 |
| CANN | Toolkit、运行依赖及产品需要的算子包，固定完整版本 | 模型编译、运行与自定义算子都有版本约束 |
| 框架 | 由 torch_npu 版本映射选择 PyTorch、Python 与 CANN | torch_npu 安装包版本和产品发布版本的命名不总相同 |
| 分析工具 | 与软件栈配套的 msProf/框架 profiler；精度工具按版本选用 | 工具更名、迁移或日落时不能照搬旧命令 |

可复现实验的历史组合示例为 PyTorch 2.5.1、torch_npu 2.5.1.post1、CANN 8.2.RC1，映射来源为官方兼容表；它不是对当前环境或维护状态的推荐。执行前选取仍受支持且适配硬件的组合，登记发布版本、包版本、来源和散列。没有核对兼容表前不执行安装。

### 1.2 公共参数与记录

```bash
export LAB=$HOME/npu-lab
mkdir -p "$LAB"/{src,models,data,results}
npu-smi info
uname -a
python3 --version
```

按实际安装版本加载 `set_env.sh`，历史 Toolkit 路径常为 `/usr/local/Ascend/ascend-toolkit/set_env.sh`，其他版本可能不同。先核对路径与文件来源，再执行 `source`，不同时加载不同 CANN 版本。

记录设备健康、温度、功率、内存、芯片/逻辑编号映射、CPU/NUMA、CANN、驱动、固件、Python、框架、算子包、源码 commit、模型散列、输入分布与随机种子。每次运行使用独立目录，保存命令、返回码、stdout/stderr 和有效配置；错误日志不得改写为成功结果。

## 2. 公共报告与验收

| 部分 | 必填内容 |
| --- | --- |
| 环境 | 具体产品、SoC、主机架构、驱动/固件、CANN 与框架版本、设备/网络拓扑 |
| 输入 | shape、layout、dtype、预处理、权重与数据散列、随机种子 |
| 正确性 | 参考实现、容差、最大绝对/相对误差、非有限值及失败样本 |
| 性能 | 冷启动、预热、设备时间和端到端时间、吞吐、内存、CPU、温度及重复样本 |
| 对照 | 相同权重/输入/负载下逐项改变精度、batch、流水或通信配置 |
| 证据 | 原始日志、编译日志、时间线、错误返回、软件回退与实际设备执行信息 |
| 限制 | 不支持的算子、数据类型、动态 shape、通信路径与未执行项目 |

每格至少三轮；稳态至少预热 10 次、测量 100 次，较慢负载可以降低次数但需明确说明。每次计时排除或包含哪些阶段必须固定。P95/P99 必须来自逐次原始样本，不能由均值补算。吞吐和精度同时报告，不预设低精度、分块或多卡一定加速。

## 3. 环境恢复

正常结束本次框架/通信进程，释放 context、stream、模型及内存；仅清理本实验生成的临时文件。恢复测试账户的环境变量、绑核和实验网络策略，不解绑未知设备、不重置其他作业正在使用的 NPU。驱动、固件、设备分区或网络配置只有在维护流程允许时才变更，并按事前记录恢复。

## 4. 参考资料与版本入口

资料核对日期：2026-10-26。官方 `master` 和在线页面会更新，实验中应固定 release/tag/commit。

- [昇腾文档入口](https://www.hiascend.com/document)：按产品和版本选择 CANN、AscendCL、ATC、Ascend C、HCCL 文档。
- [torch_npu 与快速验证](https://github.com/Ascend/pytorch)
- [torch_npu 版本映射](https://github.com/Ascend/pytorch/blob/master/COMPATIBILITY.en.md)
- [历史 v2.5.1 安装与环境说明](https://github.com/Ascend/pytorch/blob/v2.5.1/README.md)
- [AscendCL 官方样例及版本说明](https://github.com/Ascend/samples)
- [MindStudio 工具选型与迁移说明](https://github.com/Ascend/msit)：查询时已列出工具拆分及部分模块日落公告；旧 `msit benchmark` 不作为无版本约束的通用入口。
