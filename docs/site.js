// 代码目的：让介绍页中的示例切换布局、配色和 Space，不操作真实桌面。
//
// 代码逻辑：
// 1. 读取示例按钮的固定选项。
// 2. 更新预览属性和按钮的选中状态。
// 3. 同步示例标题与可访问的状态说明。
//
// 必需输入：页面内的 preview 与 data-control 按钮组。
// 预期输出：可用键盘操作的页面内布局示例。
const preview = document.getElementById("preview");
const placements = { menu: "menu bar", top: "top bar", floating: "floating bar" };
const themes = { mint: "Mint", sky: "Sky", mocha: "Mocha" };
const titles = { "1": "Workspace notes", "2": "Code workspace", "3": "Reading list" };

for (const group of document.querySelectorAll("[data-control]")) {
  group.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-value]");
    if (!button || !group.contains(button)) return;
    preview.dataset[group.dataset.control] = button.dataset.value;
    for (const option of group.querySelectorAll("button[data-value]")) {
      option.setAttribute("aria-pressed", String(option === button));
    }
    document.getElementById("example-title").textContent = titles[preview.dataset.space];
    document.getElementById("example-space").textContent = preview.dataset.space;
    document.getElementById("preview-description").textContent =
      `Illustrative preview: ${placements[preview.dataset.placement]}, ${themes[preview.dataset.theme]} theme, Space ${preview.dataset.space}. Sample windows only.`;
  });
}
