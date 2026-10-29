/// 非 Web：窗口标题与浏览器 UI 配色都由 runner 管（空实现）。
library;

void setWebDocumentTitle(String title) {}

void bindWebHead(String Function() computeTitle) {}

void unbindWebHead() {}
