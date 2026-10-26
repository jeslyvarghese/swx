// Copy buttons: copy the text of the element named by data-copy.
const confirmationDelay = 1600;

for (const button of document.querySelectorAll("[data-copy]")) {
    button.addEventListener("click", async () => {
        const source = document.getElementById(button.dataset.copy);
        if (!source) return;

        const label = button.textContent;
        try {
            await navigator.clipboard.writeText(source.textContent.trim());
            button.textContent = "Copied";
        } catch {
            button.textContent = "Select and copy";
        }
        setTimeout(() => { button.textContent = label; }, confirmationDelay);
    });
}

// Tabs: show the panel named by the selected tab's aria-controls, hide its siblings.
for (const list of document.querySelectorAll("[role=tablist]")) {
    const tabs = [...list.querySelectorAll("[role=tab]")];

    for (const tab of tabs) {
        tab.addEventListener("click", () => {
            for (const other of tabs) {
                const selected = other === tab;
                other.setAttribute("aria-selected", String(selected));
                document.getElementById(other.getAttribute("aria-controls")).hidden = !selected;
            }
        });
    }
}
