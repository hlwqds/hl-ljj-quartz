- [ ] 远程控制claude agent或者kitty
- [ ] claude code + kitty面板 
- [ ] 基于 eBPF 的 AI 代码修改全流程观测系统设计
- [ ] 基于 eBPF tracepoint 实现透明热升级 daemon：用 tracepoint/syscalls/sys_enter_bpf 监控所有 bpf() 调用，自动发现集群内 eBPF 程序拓扑，结合 bpffs watch 和 bpf_link_update 原子替换，实现无侵入的程序热升级和 map 状态迁移。核心设计点：map schema 描述与版本 diff、迁移策略（热迁移 vs 优雅停机）、回滚机制、特殊 map 类型（per-CPU、ringbuf）处理
- [ ] caracal或者suricata的性能测试专项
- [ ] 后量子算法在ipsec tls1.3 ssh协议中能拿到哪些信息
- [x] quartz支持excalidraw
- [x] deploy脚本将consul token清空了
- [x] esig也需要生成ruels到caracal对应的rules目录，我们漏掉了

```bash
● echo "net.core.wmem_max=4194304" >> /etc/sysctl.d/99-socket-buffers.conf                                                           
  echo "net.core.rmem_max=4194304" >> /etc/sysctl.d/99-socket-buffers.conf                                                         
  sysctl -p /etc/sysctl.d/99-socket-buffers.conf       
```

```bash
eBPF → ClickHouse 就够了。                                                                              
                                       
  丢包的核心瓶颈是写入链路上哪里可能堵住：                                                                                           
                                                                                                                                     
  eBPF 环形缓冲区（per-CPU，固定大小）                                                                                               
      │                                                                                                                              
      ▼ 如果满了 → 丢包                                                                                                              
  用户态读取（perf_event_array）                                                                                                     
      │                                                                                                                              
      ▼ 如果读太慢 → 环形缓冲区满 → 丢包                                                                                             
  序列化 + 发送到 ClickHouse                                                                                                         
      │                                                                                                                              
      ▼ 如果网络/ClickHouse 撑不住 → 背压 → 读变慢 → 丢包                                                                            
                                                                                                                                     
  防丢包的关键设计：                                                                                                                 
                                                                                                                                     
  1. eBPF 环形缓冲区调大                                                                                                             
  // 默认 per-CPU 通常 4MB，调到 64MB 甚至更大
  BPF_MAP_DEF(ringbuf, {                                                                                                             
      .type = BPF_MAP_TYPE_RINGBUF,                                                                                                  
      .max_entries = 64 * 1024 * 1024,  // 64MB per CPU                                                                              
  });                                                                                                                                
                                                                                                                                     
  2. 用户态读线程优先级拉高                                                                                                          
  runtime.LockOSThread()                                                                                                             
  syscall.Setpriority(syscall.PRIO_PROCESS, 0, -20)  // 最高调度优先级                                                               
                                                                                                                                     
  3. 写入端做批量攒批 + 异步                                                                                                         
  // 不要每条都写 ClickHouse，攒 1000 条或 100ms 发一次                                                                              
  batch := make([]Event, 0, 1000)                                                                                                    
  ticker := time.NewTicker(100 * time.Millisecond)                                                                                   
                                                                                                                                     
  for {                                                                                                                              
      select {                                                                                                                       
      case event := <-eventCh:                                                                                                       
          batch = append(batch, event)   
          if len(batch) >= 1000 {                                                                                                    
              ch.Insert(batch)  // 异步写                                                                                            
              batch = batch[:0]                                                                                                      
          }                                                                                                                          
      case <-ticker.C:                                                                                                               
          if len(batch) > 0 {                                                                                                        
              ch.Insert(batch)                                                                                                       
              batch = batch[:0]                                                                                                      
          }                                                                                                                          
      }                                                                                                                              
  }                                                                                                                                  
                                                                                                                                     
  4. ClickHouse 侧防丢                                                                                                               
  -- 写入用异步插入，ClickHouse 内部攒批再写盘                                                                                       
  SET async_insert = 1;                       
  SET wait_for_async_insert = 0;  -- 不等写入完成就返回                                                                              
                                                                                                                                     
  -- 表引擎选 MergeTree，不要 Replicated（复制有延迟）                                                                               
  CREATE TABLE events (                                                                                                              
      ts DateTime,                                                                                                                   
      src String,                                                                                                                    
      dst String,                        
      data String                                                                                                                    
  ) ENGINE = MergeTree()              
  ORDER BY (ts, src);                                                                                                                
                                                                                                                                     
  5. 兜底：本地落盘                                                                                                                  
                                                                                                                                     
  万一 ClickHouse 挂了或网络断了，本地先写文件：                                                                                     
  func write(event Event) {                                                                                                          
      // 1. 先写本地 WAL                                                                                                             
      wal.Append(event)                                                                                                              
                                                                                                                                     
      // 2. 异步发 ClickHouse                                                                                                        
      go func() {                                                                                                                    
          if err := ch.Insert(event); err != nil {                                                                                   
              // 失败留在 WAL，后续补发                                                                                              
              markForRetry(event)                                                                                                    
          }                                                                                                                          
      }()                              z                                                                                              
  }   
```