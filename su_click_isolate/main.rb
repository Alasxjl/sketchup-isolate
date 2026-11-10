# encoding: UTF-8
#
# Click Isolate 2.2.4
# 点击群组/组件 -> 只显示它并进入编辑；点击裸面/裸边 -> 只显示它所在的连通几何块。
# 孤立状态粘住：点画面其它位置不会取消孤立；只有手动“退出孤立”才恢复。
#
# 实现要点：
#   沿目标逐层（组/组件）或按连通块（面/边）把其余可见实体置 visible=false，
#   退出时只恢复本插件隐藏的那些，不碰用户自己隐藏的东西。
#   不用 rendering_options["InactiveHidden"]：那个开关只在编辑上下文中生效，
#   而 SketchUp 的原生交互是“点组件外任意位置就退出编辑上下文”，开关会随之失效。
#
# 依赖：SketchUp 2020+（Model#active_path=、Sketchup::InstancePath）
#
require 'sketchup.rb'

module SuClickIsolate

  PLUGIN_NAME    = 'Click Isolate'.freeze
  PLUGIN_VERSION = '2.2.4'.freeze
  PREF_SECTION   = 'SuClickIsolate'.freeze

  # 连通块搜索上限，防止在超大连通模型上把界面拖死
  MAX_BLOCK = 20_000

  # Shift 键掩码，取不到时退回 2
  SHIFT_MASK = defined?(CONSTRAIN_MODIFIER_MASK) ? CONSTRAIN_MODIFIER_MASK : 2

  # 每个模型一份状态：{ model:, path:, targets:, hidden:, prev_path: }
  #   path      = 被孤立的实例路径（裸几何孤立时为空数组）
  #   targets   = 被孤立的目标实体
  #   hidden    = 被本插件隐藏的实体列表，退出时只恢复这些
  #   prev_path = 进入孤立前所处的编辑上下文，退出时回到这里
  # 键用 object_id，取值时再用 model 对象本身校验一次，
  # 防止模型关闭后 object_id 被回收复用、状态串到新模型上。
  @state    = {}
  @watchers = {}
  @saved    = {}   # model.object_id => { entry:, hidden: } 存盘窗口快照
  @save_timer = {} # model.object_id => 重藏定时器 id，下一次存盘或退出前要取消

  class << self

    # ---------------------------------------------------------------- 状态

    def state(model)
      return nil unless model
      entry = @state[model.object_id]
      return nil unless entry && entry[:model].equal?(model)
      entry
    end

    def ensure_watcher(model)
      oid = model.object_id
      entry = @watchers[oid]
      return if entry && entry[:model].equal?(model)
      observer = ModelWatcher.new
      model.add_observer(observer)
      @watchers[oid] = { model: model, observer: observer }
    end

    # ---------------------------------------------------------------- 隐藏

    # 沿路径逐层收集“除目标外、当前可见”的实体。
    # 只有本来就可见的才记录，退出时不会把用户自己隐藏的东西显示出来。
    def collect_hidden(model, path)
      hidden = []
      context = model.entities
      path.each do |keep|
        context.each do |ent|
          next unless ent.valid?
          next if ent.entityID == keep.entityID
          next unless ent.respond_to?(:visible?) && ent.respond_to?(:visible=)
          next unless ent.visible?
          hidden << ent
        end
        begin
          context = keep.definition.entities
        rescue StandardError
          break
        end
      end
      hidden
    end

    # 指定上下文里除 targets 之外、当前可见的实体。
    # 用 Hash 而不是 Array#include?，大块几何下是 O(E+T) 而不是 O(E*T)。
    def collect_hidden_except(context, targets)
      ids = {}
      Array(targets).each { |e| ids[e.entityID] = true }
      hidden = []
      context.each do |ent|
        next unless ent.valid?
        next if ids.key?(ent.entityID)
        next unless ent.respond_to?(:visible?) && ent.respond_to?(:visible=)
        next unless ent.visible?
        hidden << ent
      end
      hidden
    end

    def hide_all(list)
      list.each do |ent|
        begin
          ent.visible = false if ent.valid? && ent.respond_to?(:visible=)
        rescue StandardError
          nil
        end
      end
    end

    # 存盘被取消、或用户撤销了隐藏操作之后，状态表还在但画面已经恢复，
    # 再点同一个对象时补一次，避免“显示没孤立、提示已在孤立中”。
    def ensure_hidden(model, entry)
      # 存盘窗口分两段：pre→post 期间记在 @saved，post→重藏定时器期间记在 @save_timer。
      # 两段都由存盘链路负责重藏，这里抢先藏会在写盘途中把隐藏状态写进文件。
      return if @saved.key?(model.object_id) || @save_timer.key?(model.object_id)
      list = (entry[:hidden] || []).select { |e| e.valid? && e.visible? }
      return if list.empty?
      with_operation(model, 'Click Isolate 重新隐藏') { hide_all(list) }
    rescue StandardError => e
      log(e)
    end

    def show_all(list)
      list.each do |ent|
        begin
          ent.visible = true if ent.valid? && ent.respond_to?(:visible=)
        rescue StandardError
          nil
        end
      end
    end

    # 包一层 undo，避免隐藏动作散落在用户的操作历史里；
    # 已有操作在开着时 start_operation 会返回 false，那就直接执行，不再套。
    def with_operation(model, name)
      opened = false
      begin
        opened = model.start_operation(name, true)
      rescue StandardError => e
        log(e)
        opened = false
      end
      begin
        yield
      ensure
        if opened
          begin
            model.commit_operation
          rescue StandardError => e
            log(e)
          end
        end
      end
    end

    # ---------------------------------------------------------------- 路径与目标

    # 用 entityID 比较，避免不同 wrapper 之间 == 不可靠
    def same_path?(a, b)
      a = Array(a).compact
      b = Array(b).compact
      return false unless a.size == b.size
      a.each_with_index.all? { |entity, i| entity.entityID == b[i].entityID }
    rescue StandardError
      false
    end

    def same_path_target?(entry, path)
      return false if entry[:path].nil? || entry[:path].empty?
      same_path?(entry[:path], path)
    end

    def same_geometry_target?(entry, targets)
      ids = Array(entry[:targets]).select { |e| e.valid? }.map(&:entityID)
      return false if ids.empty?
      ids.sort == Array(targets).select { |e| e.valid? }.map(&:entityID).sort
    rescue StandardError
      false
    end

    # 面/边所在的连通几何块。
    # 不用 all_connected：它的“是否递归到整块”在文档里没写死，各版本行为不一致，
    # 递归时逐层再调会退化成 O(N^2)。这里用 Face#edges / Edge#faces / Vertex#edges
    # 自己做一层扩展，语义确定，复杂度线性。
    # 返回 [实体数组, 是否被 MAX_BLOCK 截断]
    def connected_block(entity)
      unless entity.is_a?(Sketchup::Face) || entity.is_a?(Sketchup::Edge)
        return [[entity], false]
      end

      seen = {}
      queue = [entity]
      truncated = false

      until queue.empty?
        current = queue.shift
        next unless current.valid?
        next if seen.key?(current.entityID)
        seen[current.entityID] = current
        if seen.size >= MAX_BLOCK
          truncated = true
          break
        end

        begin
          if current.is_a?(Sketchup::Face)
            current.edges.each do |edge|
              queue << edge unless seen.key?(edge.entityID)
            end
          else
            current.faces.each do |face|
              queue << face unless seen.key?(face.entityID)
            end
            # 只有边没有面时（折线），靠共享顶点把相邻的边串起来
            current.vertices.each do |vertex|
              vertex.edges.each do |edge|
                queue << edge unless seen.key?(edge.entityID)
              end
            end
          end
        rescue StandardError
          nil
        end
      end

      [seen.values, truncated]
    end

    # ---------------------------------------------------------------- 动作

    def version_ok?
      return true if Sketchup.version.to_i >= 20
      UI.messagebox('Click Isolate 需要 SketchUp 2020 或更高版本。')
      false
    end

    # path: 从模型根到目标实例的完整实例路径（数组）
    def isolate(model, path, exit_tool = false)
      return false unless version_ok?

      path = Array(path).compact
      if path.empty?
        Sketchup.set_status_text('Click Isolate：没点到群组/组件')
        back_to_select_tool(model) if exit_tool
        return false
      end

      entry = state(model)
      if entry && same_path_target?(entry, path)
        # 原生交互下点组件外就会退出编辑上下文，这里要把上下文补回去，
        # 否则“再点一下这个组”只会得到一句提示，人进不去。
        begin
          model.active_path = Sketchup::InstancePath.new(path)
        rescue StandardError => e
          log(e)
        end
        ensure_hidden(model, entry)
        back_to_select_tool(model) if exit_tool
        Sketchup.set_status_text("Click Isolate：已在孤立 #{display_name(path.last)} 中")
        return true
      end

      locked = locked_instance(path)
      if locked
        Sketchup.set_status_text("Click Isolate：#{display_name(locked)} 或其同定义实例已锁定，无法进入编辑")
        back_to_select_tool(model) if exit_tool
        return false
      end

      old = entry
      prev_path = old ? Array(old[:prev_path]).compact : (model.active_path || []).to_a

      # 先试着进新目标，成功后再拆掉旧孤立：进不去时旧孤立还能留着。
      begin
        model.active_path = Sketchup::InstancePath.new(path)
      rescue StandardError => e
        if old
          begin
            model.active_path = Sketchup::InstancePath.new(old[:path]) unless old[:path].empty?
          rescue StandardError
            nil
          end
          ensure_hidden(model, old)
        end
        Sketchup.set_status_text("Click Isolate：无法进入编辑上下文（#{e.message}）")
        back_to_select_tool(model) if exit_tool
        return false
      end

      release(model, old) if old

      hidden = begin
        collect_hidden(model, path)
      rescue StandardError => e
        log(e)
        []
      end

      begin
        with_operation(model, 'Click Isolate 孤立') { hide_all(hidden) }
      rescue StandardError => e
        log(e)
      end

      @state[model.object_id] = {
        model:     model,
        path:      path,
        targets:   path,
        hidden:    hidden,
        prev_path: prev_path
      }
      ensure_watcher(model)

      Sketchup.set_status_text("Click Isolate：已孤立 #{display_name(path.last)}　（点“退出孤立”恢复）")
      back_to_select_tool(model) if exit_tool
      true
    end

    # 孤立一组裸几何（面/边，或用户多选的对象）：
    # 不进入编辑上下文，只把当前上下文里其余可见实体藏起来。
    def isolate_entities(model, list)
      return false unless version_ok?

      targets = Array(list).select { |e| e && e.valid? }.uniq { |e| e.entityID }
      if targets.empty?
        Sketchup.set_status_text('Click Isolate：没有可孤立的对象')
        return false
      end

      entry = state(model)
      if entry && same_geometry_target?(entry, targets)
        ensure_hidden(model, entry)
        Sketchup.set_status_text("Click Isolate：已在孤立 #{display_name(targets.first)} 中")
        return true
      end

      # restore 会把 active_path 拉回上一次孤立之前的位置。
      # 如果这次的目标在更深的上下文里，必须先切回去，否则会在外层上下文里
      # “除了 targets 全隐藏”，而 targets 根本不在这一层，画面会整片空掉。
      cur_path = (model.active_path || []).to_a
      prev_path = entry ? Array(entry[:prev_path]).compact : cur_path
      restore(model) if entry
      unless cur_path.empty?
        begin
          model.active_path = Sketchup::InstancePath.new(cur_path)
        rescue StandardError => e
          log(e)
        end
      end

      context = model.active_entities
      ancestors = (model.active_path || []).to_a
      present = {}
      context.each { |e| present[e.entityID] = true }
      unless targets.all? { |t| present.key?(t.entityID) }
        Sketchup.set_status_text('Click Isolate：选中的对象不在当前编辑上下文中')
        return false
      end

      # 只藏当前上下文里的兄弟还不够：人在组里时，组外面的模型仍然可见，
      # 看起来就像“只在组内孤立”。沿 active_path 把每一层的兄弟一起藏掉，
      # 孤立范围和“点群组”那条分支保持一致。
      hidden = collect_hidden(model, ancestors)
      hidden.concat(collect_hidden_except(context, targets))

      begin
        with_operation(model, 'Click Isolate 孤立') { hide_all(hidden) }
      rescue StandardError => e
        log(e)
      end

      @state[model.object_id] = {
        model:     model,
        path:      [],
        targets:   targets,
        hidden:    hidden,
        prev_path: prev_path
      }
      ensure_watcher(model)

      Sketchup.set_status_text("Click Isolate：已孤立 #{display_name(targets.first)}　（点“退出孤立”恢复）")
      true
    end

    # 点到裸面/裸边：孤立它所在的连通块
    def isolate_geometry(model, entity)
      unless entity.is_a?(Sketchup::Face) || entity.is_a?(Sketchup::Edge)
        Sketchup.set_status_text('Click Isolate：点到的不是群组/组件/面/边')
        return false
      end

      block, truncated = connected_block(entity)
      if truncated
        Sketchup.set_status_text("Click Isolate：这块几何超过 #{MAX_BLOCK} 个面/边，请改用“孤立选中对象”或先成组")
        return false
      end

      isolate_entities(model, block)
    end

    # 拆掉一次孤立：恢复显示，但不动 active_path。
    # 用于“换目标”时清理旧状态，因为新上下文刚刚设好，不能被旧路径覆盖。
    def release(model, entry)
      return unless entry
      cancel_save_timer(model)
      begin
        with_operation(model, 'Click Isolate 切换目标') { show_all(entry[:hidden] || []) }
      rescue StandardError => e
        log(e)
      end
      @state.delete(model.object_id)
    end

    # 恢复到进入孤立之前：显示被隐藏的实体，回到原来的编辑上下文
    def restore(model)
      entry = state(model)
      return false unless entry
      cancel_save_timer(model)

      hidden = entry[:hidden] || []
      begin
        with_operation(model, 'Click Isolate 退出孤立') { show_all(hidden) }
      rescue StandardError => e
        log(e)
      end

      begin
        prev = Array(entry[:prev_path]).compact
        model.active_path = prev.empty? ? nil : Sketchup::InstancePath.new(prev)
      rescue StandardError => e
        log(e)
      end

      @state.delete(model.object_id)
      true
    end

    # 模型关闭/删除时尽力收尾，并清掉状态表
    def forget(model)
      return unless model
      entry = state(model)
      if entry
        begin
          show_all(entry[:hidden] || [])
        rescue StandardError
          nil
        end
        @state.delete(model.object_id)
      end
      cancel_save_timer(model)
      @watchers.delete(model.object_id)
      @saved.delete(model.object_id)
    end

    # 切回默认的选择工具，让用户马上能编辑；延迟一帧执行，避免在工具回调里重入
    def back_to_select_tool(model)
      UI.start_timer(0, false) do
        begin
          model.select_tool(nil)
        rescue StandardError
          begin
            Sketchup.send_action('selectSelectionTool:')
          rescue StandardError
            nil
          end
        end
      end
    end

    # 孤立当前选中的对象：
    #   单个群组/组件 -> 进入它的编辑上下文
    #   其它（面、边、多个对象）-> 只显示选中的这些
    def isolate_selection(model)
      return false unless model
      return false unless version_ok?

      picked = model.selection.to_a.select { |e| e && e.valid? }
      if picked.empty?
        # 这里绝不能用 UI.messagebox。模态框会截断 SketchUp 的 Windows 消息循环，
        # 从菜单/工具栏回调里弹出来时主窗口失去响应，表现为“弹个框然后卡死”。
        # 提示统一走状态栏：不阻塞、不抢焦点、不打断正在进行的操作。
        Sketchup.set_status_text('Click Isolate：没有选中对象。请先选中，或用工具栏的“点击孤立”直接点')
        return false
      end

      groups = picked.select do |e|
        e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
      end

      if picked.size == 1 && groups.size == 1
        inst = groups.first
        unless model.active_entities.include?(inst)
          Sketchup.set_status_text('Click Isolate：该对象不在当前编辑上下文中，先用“点击孤立”工具点它')
          return false
        end
        return isolate(model, (model.active_path || []).to_a + [inst], false)
      end

      isolate_entities(model, picked)
    end

    def exit_isolation(model = Sketchup.active_model)
      unless model
        Sketchup.set_status_text('Click Isolate：没有打开的模型')
        return
      end

      if restore(model)
        Sketchup.set_status_text('Click Isolate：已退出孤立')
      else
        Sketchup.set_status_text('Click Isolate：当前没有孤立状态')
      end
    end

    # ---------------------------------------------------------------- 回调

    # 取消上一次存盘排下的重藏定时器。连续两次 Ctrl+S 时，
    # 第一次的定时器会在第二次写盘过程中把实体重新藏起来，
    # 那样写进 .skp 的就会是“只剩一个物体可见”。
    def cancel_save_timer(model)
      id = @save_timer.delete(model.object_id)
      return unless id
      begin
        UI.stop_timer(id)
      rescue StandardError => e
        log(e)
      end
    end

    # 存盘前把实体显示回来，别让“只剩一个物体可见”的状态写进 .skp；
    # 存完再隐藏回去，孤立状态不会因为存盘被打断。
    #
    # 借用 HideMoreLess 的思路：SketchUp 存盘会关闭再重开所有打开的组件，
    # 回调顺序和用户手动操作无法区分。所以不在 post 回调里立刻重藏，
    # 而是记下这次存盘对应的状态对象，延后一拍，确认仍是同一次孤立、
    # 且用户没有在存盘窗口里点“退出孤立”，再恢复隐藏。
    # 这里不包 start_operation：观察者回调里开事务容易和 SketchUp 自己的保存
    # 事务打架，而且这两次临时改动不该出现在用户的撤销历史里。
    def on_pre_save(model)
      cancel_save_timer(model)
      entry = state(model)
      return unless entry
      list = Array(entry[:hidden]).select { |e| e.valid? }
      return if list.empty?
      @saved[model.object_id] = { entry: entry, hidden: list }
      begin
        show_all(list)
      rescue StandardError => e
        log(e)
      end
    rescue StandardError => e
      log(e)
    end

    def on_post_save(model)
      record = @saved.delete(model.object_id)
      return unless record
      # 延后一拍：post 回调之后 SketchUp 才把组件重新打开，
      # 立刻重藏会被随后的重开覆盖，视图还会闪一下。
      @save_timer[model.object_id] = UI.start_timer(0.2, false) do
        @save_timer.delete(model.object_id)
        begin
          # 存盘期间用户点了“退出孤立”，state 已不是原来那个对象，不能再藏回去
          next unless state(model).equal?(record[:entry])
          list = record[:hidden].select { |e| e.valid? }
          hide_all(list)
        rescue StandardError => e
          log(e)
        end
      end
    rescue StandardError => e
      log(e)
    end

    # ---------------------------------------------------------------- 杂项

    # 同一定义下只要有一个实例被锁，active_path= 就会抛 ArgumentError，
    # 所以预检要把兄弟实例一起看了，别等异常再处理。
    def locked_instance(path)
      path.find do |inst|
        begin
          next true if inst.locked?
          next false unless inst.respond_to?(:definition)
          inst.definition.instances.any? { |other| other.locked? }
        rescue StandardError
          false
        end
      end
    end

    def display_name(entity)
      return '对象' unless entity && entity.valid?
      return '面' if entity.is_a?(Sketchup::Face)
      return '边' if entity.is_a?(Sketchup::Edge)

      name = entity.respond_to?(:name) ? entity.name.to_s : ''
      if name.empty? && entity.respond_to?(:definition)
        name = entity.definition.name.to_s
      end
      name = entity.typename if name.empty?
      name
    rescue StandardError
      '对象'
    end

    def log(err)
      puts "[Click Isolate] #{err.class}: #{err.message}"
    rescue StandardError
      nil
    end

  end

  # ------------------------------------------------------------------ 观察者

  class ModelWatcher < Sketchup::ModelObserver
    def onPreSaveModel(model)
      SuClickIsolate.on_pre_save(model)
    end

    def onPostSaveModel(model)
      SuClickIsolate.on_post_save(model)
    end

    # 已废弃，但在部分版本上仍会回调；能收尾就收尾
    def onDeleteModel(model)
      SuClickIsolate.forget(model)
    end
  end

  # ------------------------------------------------------------------ 工具

  class IsolateTool

    def activate
      Sketchup.set_status_text('点击群组/组件或裸面/裸边：孤立并显示　|　Shift+点击：钻到最深层　|　退出请点“退出孤立”')
    end

    def deactivate(view)
      view.invalidate if view.respond_to?(:invalidate)
    end

    # 这里不恢复孤立。切工具时部分版本也会走到 onCancel
    def onCancel(_reason, _view)
      Sketchup.set_status_text('Click Isolate：已取消')
      false
    end

    def onLButtonDown(flags, x, y, view)
      model = view.model
      ph = view.pick_helper
      ph.do_pick(x, y)

      if ph.count == 0
        Sketchup.set_status_text('Click Isolate：这里没有东西')
        return
      end

      chain = pick_chain(ph, 0)
      if chain.empty?
        # picked_element 按文档永远不会返回边或面，必须用 best_picked。
        element = begin
          ph.best_picked
        rescue StandardError
          nil
        end
        if element.is_a?(Sketchup::Face) || element.is_a?(Sketchup::Edge)
          SuClickIsolate.isolate_geometry(model, element)
        else
          Sketchup.set_status_text('Click Isolate：这里没有可孤立的对象')
        end
        return
      end

      drill = (flags & SHIFT_MASK) != 0
      target = drill ? chain : [chain.first]
      SuClickIsolate.isolate(model, (model.active_path || []).to_a + target, true)
    end

    private

    # 拾取路径里从当前上下文往下的连续群组/组件链
    def pick_chain(pick_helper, index)
      chain = []
      path = pick_helper.path_at(index)
      return chain if path.nil?
      path.each do |entity|
        if entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          chain << entity
        else
          break
        end
      end
      chain
    end

  end

  # ------------------------------------------------------------------ 界面

  unless file_loaded?(__FILE__)

    icons = File.join(__dir__, 'icons')

    cmd_isolate = UI::Command.new('点击孤立') do
      model = Sketchup.active_model
      model.select_tool(IsolateTool.new) if model
    end
    cmd_isolate.small_icon      = File.join(icons, 'isolate_24.png')
    cmd_isolate.large_icon      = File.join(icons, 'isolate_32.png')
    cmd_isolate.menu_text       = '点击孤立并编辑'
    cmd_isolate.tooltip         = '点击群组、组件或裸面/裸边：只显示它'
    cmd_isolate.status_bar_text = '点击群组/组件/裸面/裸边孤立；Shift+点击钻到最深层；退出请点“退出孤立”'

    # 菜单/工具栏回调里直接动模型或弹窗，会打断 Windows 的消息分发。
    # 延后一帧执行，让回调栈先干净地返回，是 SketchUp 插件规避重入卡死的标准做法。
    # 定时器回调里漏出去的异常会由 SketchUp 自己弹错误框，所以在这里兜住。
    cmd_selection = UI::Command.new('孤立选中对象') do
      UI.start_timer(0, false) do
        begin
          SuClickIsolate.isolate_selection(Sketchup.active_model)
        rescue StandardError => e
          SuClickIsolate.log(e)
          Sketchup.set_status_text("Click Isolate：操作失败（#{e.message}）")
        end
      end
    end

    cmd_exit = UI::Command.new('退出孤立') do
      UI.start_timer(0, false) do
        begin
          SuClickIsolate.exit_isolation(Sketchup.active_model)
        rescue StandardError => e
          SuClickIsolate.log(e)
          Sketchup.set_status_text("Click Isolate：退出失败（#{e.message}）")
        end
      end
    end
    cmd_exit.small_icon      = File.join(icons, 'exit_24.png')
    cmd_exit.large_icon      = File.join(icons, 'exit_32.png')
    cmd_exit.menu_text       = '退出孤立'
    cmd_exit.tooltip         = '恢复被隐藏的其余对象，回到进入孤立前的编辑位置'
    cmd_exit.status_bar_text = '退出孤立，恢复模型其余部分显示'

    extensions_menu = UI.menu('Extensions')
    extensions_menu.add_item(cmd_isolate)
    extensions_menu.add_item(cmd_selection)
    extensions_menu.add_item(cmd_exit)

    toolbar = UI::Toolbar.new(PLUGIN_NAME)
    toolbar.add_item(cmd_isolate)
    toolbar.add_item(cmd_exit)
    toolbar.restore
    # 首次安装时 restore 不会把工具栏显示出来，补一次 show；之后尊重用户自己的显示状态
    unless Sketchup.read_default(PREF_SECTION, 'toolbar_shown', false)
      toolbar.show
      Sketchup.write_default(PREF_SECTION, 'toolbar_shown', true)
    end

    # 右键菜单：选中对象后直接孤立，孤立中随时退出。
    # 入口布局借鉴 VisTools：菜单、工具栏、右键菜单指向同一批命令。
    UI.add_context_menu_handler do |menu|
      model = Sketchup.active_model
      next unless model
      picked = !model.selection.empty?
      isolated = SuClickIsolate.state(model)
      next unless picked || isolated
      menu.add_separator
      menu.add_item(cmd_selection) if picked
      menu.add_item(cmd_exit) if isolated
    end

    file_loaded(__FILE__)
  end

end
