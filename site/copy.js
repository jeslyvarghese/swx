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
