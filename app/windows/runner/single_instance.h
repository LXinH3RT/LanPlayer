#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

// 桌面图标再点一次时不再开第二个窗口。
//
// 实现见 single_instance.cpp：第一个实例抓住一个命名 mutex，第二个实例发现
// 它已存在就把那个窗口还原、提到前台，然后让调用方直接退出。第二次启动带的
// 命令行参数（文件关联拖进来的片子）这一版不转发。
//
// 这个文件不在 scripts/gen_windows_runner.py 的模板产物里，重新生成
// app/windows/ 不会删掉它；但生成脚本会往 main.cpp 与 runner/CMakeLists.txt
// 里补上引用，否则新进程根本没机会调用到这里。
bool ActivateRunningInstance();

#endif  // RUNNER_SINGLE_INSTANCE_H_
