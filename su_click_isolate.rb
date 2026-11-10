# encoding: UTF-8
#
# Click Isolate —— 扩展加载入口
# 安装：把 su_click_isolate.rb 和 su_click_isolate 文件夹一起放进 Plugins 目录，
#       或用“扩展程序管理器”安装 SuClickIsolate.rbz。
#
require 'sketchup.rb'
require 'extensions.rb'

module SuClickIsolate
  PLUGIN_ID   = File.basename(__FILE__, '.rb').freeze
  PLUGIN_DIR  = File.join(__dir__, PLUGIN_ID)
  MAIN_FILE   = File.join(PLUGIN_DIR, 'main.rb')

  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new('Click Isolate', MAIN_FILE)
    extension.description = '点击群组/组件即只显示它并进入编辑；孤立状态保持到你手动退出，退出时恢复其余对象。'
    extension.version     = '2.2.4'
    extension.creator     = 'pojia'
    extension.copyright   = '2026'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
