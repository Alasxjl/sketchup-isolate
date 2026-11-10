# Click Isolate for SketchUp

点击即孤立：点一个群组、组件、裸面或裸边，只显示它，其余全部隐藏。孤立状态粘住，点画面其它位置不会取消，只有点“退出孤立”才恢复。

需要 SketchUp 2020 或更高版本。

## 功能

- **点击孤立**：点群组或组件，进入它的编辑上下文并只显示它；`Shift + 点击` 直接钻到光标下最深的实例
- **裸几何**：点未成组的面或边，孤立它所在的连通几何块（沿共享边搜索，不限于单个面）
- **组内孤立**：在组里孤立对象时，组外的模型一起隐藏，不只是组内兄弟
- **只恢复自己的**：退出时只显示插件隐藏过的对象，你手动隐藏的东西保持隐藏
- **存盘不残留**：存盘前临时恢复显示，存完自动重藏，`.skp` 里不会留下“只剩一个物体可见”的状态
- **三个入口**：Extensions 菜单、工具栏按钮、右键菜单

## 安装

**方式一**：SketchUp 菜单 → 窗口 → 扩展程序管理器 → 安装扩展程序 → 选 `SuClickIsolate.rbz`。

**方式二**：把 `su_click_isolate.rb` 和 `su_click_isolate/` 目录一起复制到 SketchUp 的 `Plugins` 目录：

- Windows：`%AppData%\SketchUp\SketchUp 20xx\SketchUp\Plugins`
- macOS：`~/Library/Application Support/SketchUp 20xx/SketchUp/Plugins`

## 使用

1. 点工具栏的橙色方块按钮，或 Extensions → 点击孤立并编辑
2. 点场景里的群组／组件／面／边，其余对象立即隐藏
3. 点画面空白处只会退出编辑上下文，孤立保持
4. 点工具栏灰色方块按钮，或 Extensions → 退出孤立，恢复全部显示

也可以先选中对象，再用 Extensions → 孤立选中对象，或右键菜单。

## 实现方式

不用 `rendering_options["InactiveHidden"]`（视图 → 组件编辑 → 隐藏模型其余部分）。那个开关只在编辑上下文中生效，而 SketchUp 的原生交互是“点组件外任意位置就退出编辑上下文”，开关会随之失效，做不到“粘住”。

实际做法是把其余可见实体置 `visible = false`：

- 群组／组件：从模型根沿实例路径逐层收集除目标外的可见实体
- 裸面／裸边：先沿路径隐藏各层兄弟，再对当前上下文做连通块搜索（`Face#edges` / `Edge#faces` / `Vertex#edges`），只留连通块
- 退出时只对记录过的实体置 `visible = true`，用户自己隐藏的不在记录里

连通块搜索上限 20000 个面／边，超限会拒绝执行并提示，避免在整体连通的模型上卡死。

## 已知限制

- 隐藏操作会写入撤销栈，按 Ctrl+Z 会撤销孤立
- 同一组件定义的其它实例共享几何，孤立其中的实体会影响同定义的实例；孤立期间它们本来也已被隐藏
- 存盘若被取消或写盘失败，画面会停在“全部可见”而状态表仍记着孤立，再成功存盘一次或点“退出孤立”可复位
- 没有右键“在此处孤立”之外的场景管理功能，不处理图层／标记可见性

## 文件结构

```
SuClickIsolate/
├── SuClickIsolate.rbz        打包好的安装文件
├── su_click_isolate.rb       扩展加载入口
└── su_click_isolate/
    ├── main.rb               全部逻辑
    └── icons/                工具栏图标（24/32 px）
```

## 开发

改完 `su_click_isolate/main.rb` 后，把 `su_click_isolate.rb` 与 `su_click_isolate/` 目录按原结构压成 zip，扩展名改成 `.rbz` 即可安装。

Ruby 语法自检：

```
ruby -c su_click_isolate.rb
ruby -c su_click_isolate/main.rb
```

## 许可证

[MIT](LICENSE)
