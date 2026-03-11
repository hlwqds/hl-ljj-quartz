---
layout: post
title: Go Context 超时自动取消场景详解
date: 2025-12-17 10:00:00 +0800
pin: true
tags: [go, context]
---

# Context 超时自动取消场景详解

`context.WithTimeout` 是 Go 语言中最常用的 Context 变体之一，用于设置操作的最大执行时间。当超时发生时，会自动取消所有基于该 Context 的操作。

## 目录

- [基本概念](#基本概念)
- [HTTP 请求超时](#http-请求超时)
- [数据库查询超时](#数据库查询超时)
- [多服务聚合超时](#多服务聚合超时)
- [文件处理超时](#文件处理超时)
- [带重试的超时控制](#带重试的超时控制)
- [Websocket 连接超时](#websocket-连接超时)
- [GRPC 调用超时](#grpc-调用超时)
- [最佳实践](#最佳实践)

---

## 基本概念

### 什么是 Context.WithTimeout

```go
ctx, cancel := context.WithTimeout(parentContext, duration)
defer cancel()
```

- **作用**：创建一个在指定时间后自动取消的 Context
- **参数**：父 Context 和超时时长
- **返回**：新的 Context 和取消函数
- **必须调用**：`defer cancel()` 防止 goroutine 泄漏

### 超时检测

```go
select {
case <-ctx.Done():
    if errors.Is(ctx.Err(), context.DeadlineExceeded) {
        // 超时处理
    }
}
```

---

## HTTP 请求超时

### 代码示例

```go:go
func fetchUserDataAPI(userID string) (*User, error) {
    // 3秒超时
    ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
    defer cancel() // 必须调用，防止内存泄漏

    req, err := http.NewRequestWithContext(ctx, "GET", "https://api.example.com/users/"+userID, nil)
    if err != nil {
        return nil, err
    }

    resp, err := http.DefaultClient.Do(req)
    if err != nil {
        // 检查是否是超时
        if errors.Is(err, context.DeadlineExceeded) {
            return nil, fmt.Errorf("请求超时")
        }
        return nil, err
    }
    defer resp.Body.Close()

    // 解析响应
    var user User
    if err := json.NewDecoder(resp.Body).Decode(&user); err != nil {
        return nil, err
    }

    return &user, nil
}
```

**适用场景**：调用外部 API、微服务接口

---

## 数据库查询超时

### 代码示例

```go:go
func getUserWithTimeout(db *sql.DB, userID int) (*User, error) {
    ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
    defer cancel()

    // 这个查询如果超过2秒会被取消
    row := db.QueryRowContext(ctx, "SELECT * FROM users WHERE id = ?", userID)

    var user User
    err := row.Scan(&user.ID, &user.Name, &user.Email)
    if err != nil {
        if errors.Is(err, context.DeadlineExceeded) {
            return nil, fmt.Errorf("数据库查询超时")
        }
        return nil, err
    }

    return &user, nil
}
```

**适用场景**：慢查询预防、防止数据库连接长时间占用

---

## 多服务聚合超时

### 代码示例

```go:go
func getUserInfoCombined(userID string) (*UserInfo, error) {
    // 总共最多等 5 秒
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()

    userChan := make(chan *User, 1)
    profileChan := make(chan *Profile, 1)
    errChan := make(chan error, 2)

    // 并行调用用户服务
    go func() {
        user, err := userService(ctx, userID)
        if err != nil {
            errChan <- err
            return
        }
        userChan <- user
    }()

    // 并行调用档案服务
    go func() {
        profile, err := profileService(ctx, userID)
        if err != nil {
            errChan <- err
            return
        }
        profileChan <- profile
    }()

    // 收集结果
    var userInfo UserInfo
    ctxDone := ctx.Done()

    for {
        select {
        case user := <-userChan:
            userInfo.User = user
            if userInfo.Profile != nil {
                return &userInfo, nil
            }
        case profile := <-profileChan:
            userInfo.Profile = profile
            if userInfo.User != nil {
                return &userInfo, nil
            }
        case err := <-errChan:
            return nil, err
        case <-ctxDone:
            return nil, fmt.Errorf("总超时：未能在5秒内获取所有信息")
        }
    }
}
```

**适用场景**：聚合多个微服务数据，确保总响应时间可控

---

## 文件处理超时

### 代码示例

```go:go
func processLargeFile(filePath string) error {
    ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
    defer cancel()

    file, err := os.Open(filePath)
    if err != nil {
        return err
    }
    defer file.Close()

    scanner := bufio.NewScanner(file)
    lineNum := 0

    for scanner.Scan() {
        select {
        case <-ctx.Done():
            if errors.Is(ctx.Err(), context.DeadlineExceeded) {
                return fmt.Errorf("文件处理超时，已处理 %d 行", lineNum)
            }
            return ctx.Err()
        default:
            // 处理每一行
            line := scanner.Text()
            processLine(line)
            lineNum++
        }
    }

    return scanner.Err()
}
```

**适用场景**：大文件处理、批量任务处理

---

## 带重试的超时控制

### 代码示例

```go:go
func fetchDataWithRetry(ctx context.Context, url string) (string, error) {
    // 继承父 Context 的超时，或创建新的
    ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
    defer cancel()

    maxRetries := 3
    var lastErr error

    for i := 0; i < maxRetries; i++ {
        // 检查是否已经超时
        if errors.Is(ctx.Err(), context.DeadlineExceeded) {
            return "", fmt.Errorf("超时，已重试 %d 次", i)
        }

        data, err := fetchURL(ctx, url)
        if err == nil {
            return data, nil
        }

        lastErr = err

        // 重试前检查剩下时间
        if deadline, ok := ctx.Deadline(); ok {
            remaining := time.Until(deadline)
            if remaining < 1*time.Second {
                return "", fmt.Errorf("剩余时间不足，放弃重试")
            }

            // 指数退避，但不超过剩余时间
            backoff := time.Duration(i*i) * 100 * time.Millisecond
            if backoff > remaining {
                backoff = remaining / 2
            }

            select {
            case <-time.After(backoff):
            case <-ctx.Done():
                return "", ctx.Err()
            }
        }
    }

    return "", fmt.Errorf("最终失败: %w", lastErr)
}
```

**适用场景**：网络请求重试、不稳定服务调用

---

## Websocket 连接超时

### 代码示例

```go:go
func handleWebSocket(conn *websocket.Conn) {
    // 整个会话最多 5 分钟
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
    defer cancel()

    // 设置读写超时
    conn.SetReadDeadline(time.Now().Add(30 * time.Second))
    conn.SetWriteDeadline(time.Now().Add(30 * time.Second))

    for {
        select {
        case <-ctx.Done():
            if errors.Is(ctx.Err(), context.DeadlineExceeded) {
                conn.WriteControl(websocket.CloseMessage,
                    []byte("会话超时"), time.Now().Add(1*time.Second))
            }
            return

        default:
            // 读取消息
            _, msg, err := conn.ReadMessage()
            if err != nil {
                if websocket.IsUnexpectedCloseError(err, websocket.CloseNormalClosure) {
                    return
                }
                // 可能是读超时
                if errors.Is(err, context.DeadlineExceeded) || netErr, ok := err.(net.Error); ok && netErr.Timeout() {
                    conn.WriteControl(websocket.CloseMessage,
                        []byte("读取超时"), time.Now().Add(1*time.Second))
                    return
                }
            }

            // 处理消息
            processMessage(msg)
        }
    }
}
```

**适用场景**：WebSocket 长连接、实时通信

---

## GRPC 调用超时

### 代码示例

```go:go
func callGrpcWithTimeout() {
    // 设置连接超时
    connCtx, connCancel := context.WithTimeout(context.Background(), 2*time.Second)
    defer connCancel()

    conn, err := grpc.DialContext(connCtx, "localhost:50051", grpc.WithInsecure())
    if err != nil {
        log.Fatal("连接超时:", err)
    }
    defer conn.Close()

    client := pb.NewUserServiceClient(conn)

    // 设置 RPC 调用超时
    rpcCtx, rpcCancel := context.WithTimeout(context.Background(), 3*time.Second)
    defer rpcCancel()

    user, err := client.GetUser(rpcCtx, &pb.GetUserRequest{Id: "123"})
    if err != nil {
        if status.Code(err) == codes.DeadlineExceeded {
            log.Fatal("RPC 调用超时")
        }
        log.Fatal(err)
    }

    fmt.Printf("获取用户: %+v\n", user)
}
```

**适用场景**：gRPC 微服务调用、分布式系统调用

---

## 最佳实践

### 1. 始终使用 defer cancel()

```go:go
func bestPractice() {
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel() // 必须！防止 goroutine 泄漏
    // ... 其他代码
}
```

### 2. 检查超时原因

```go:go
select {
case <-ctx.Done():
    if errors.Is(ctx.Err(), context.DeadlineExceeded) {
        fmt.Println("超时了")
    } else {
        fmt.Println("其他错误:", ctx.Err())
    }
}
```

### 3. 获取剩余时间

```go:go
if deadline, ok := ctx.Deadline(); ok {
    remaining := time.Until(deadline)
    fmt.Printf("剩余时间: %v\n", remaining)
}
```

### 4. 合理设置超时时间

| 场景           | 典型超时时间 |
| -------------- | ------------ |
| 外部 API 调用  | 3-5 秒       |
| 数据库查询     | 2-10 秒      |
| 文件操作       | 10-30 秒     |
| 微服务调用     | 1-3 秒       |
| 批量处理       | 30-300 秒    |
| WebSocket 连接 | 5-60 分钟    |

### 5. 继承父 Context

```go:go
func processOrder(parentCtx context.Context, order Order) error {
    // 继承父 Context 的超时和取消信号
    ctx, cancel := context.WithTimeout(parentCtx, 10*time.Second)
    defer cancel()

    // ... 业务逻辑
    return nil
}
```

---

## 总结

### 核心要点

1. **Always defer cancel()** - 防止内存泄漏
2. **Check ctx.Done()** - 及时响应取消信号
3. **Respect parent Context** - 继承上游的超时和取消
4. **Set reasonable timeouts** - 根据场景设置合适的超时时间
5. **Handle DeadlineExceeded** - 区分超时和其他错误

### 何时使用

- ✅ 调用外部服务（API、数据库、第三方）
- ✅ 并行执行多个操作，需要整体时间控制
- ✅ 防止慢操作拖垮整个系统
- ✅ 需要快速失败（fail-fast）机制
- ✅ 担心 goroutine 泄漏

### 何时不需要

- ❌ 超快的内存操作
- ❌ 有其他更合适的取消机制
- ❌ 真正需要无限等待的操作
