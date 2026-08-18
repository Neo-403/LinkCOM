// 全局主题切换: 点击左上 LinkCOM 文字在 亮/暗 间切换, 状态存 localStorage
(function () {
  function toggleTheme() {
    var cur = document.documentElement.getAttribute('data-theme') === 'light' ? 'light' : 'dark';
    var next = cur === 'light' ? 'dark' : 'light';
    document.documentElement.setAttribute('data-theme', next);
    try { localStorage.setItem('linkcom-theme', next); } catch (e) {}
    var logo = document.querySelector('header .logo');
    if (logo) {
      var old = logo.title;
      logo.title = (next === 'light' ? '当前: 亮色 (点击切换为暗色)' : '当前: 暗色 (点击切换为亮色)');
    }
  }

  function init() {
    var logo = document.querySelector('header .logo');
    if (!logo) return;
    logo.style.cursor = 'pointer';
    var cur = document.documentElement.getAttribute('data-theme') === 'light' ? 'light' : 'dark';
    logo.title = (cur === 'light' ? '当前: 亮色 (点击切换为暗色)' : '当前: 暗色 (点击切换为亮色)');
    logo.addEventListener('click', toggleTheme);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
