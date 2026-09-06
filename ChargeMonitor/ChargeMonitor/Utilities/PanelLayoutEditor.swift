import Foundation

// v1.13 列式布局（PanelLayout 三表 + PanelLayoutEditor 移动/换列纯函数）已被
// 华容网格 v3 取代：用户只拥有阅读序+眼睛，列与宽由 PanelFlow 结构配对纯推导。
// 数据定义与纯函数现居 PanelFlow.swift；旧档 {left,right,hidden} 由
// PanelLayout.effectiveFlow 回退读取，见 PanelFlow.normalize。
