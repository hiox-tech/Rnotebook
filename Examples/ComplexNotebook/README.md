# 复杂QMD验证示例

打开“复杂验证.qmd”，点击运行全部。共12个R代码块，240条模拟数据、233个完整配对、600次Bootstrap及多种原生输出。

measurements.csv为普通外部输入；不建立App项目。最后一个块应输出COMPLEX_VALIDATION_OK。第一块故意产生一条message及一条warning用于检查条件显示。

支持在同一会话重复运行全文；通过标记会显示累计run_count，每次运行Bootstrap重新计算一次。独立测试另外断言首次运行及视图往返后计数为1、第二次显式运行后为2，独立Quarto导出使用新会话。
