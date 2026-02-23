// PR Picker Hook
// Combobox-style picker for selecting PRs in the new deployment form.
// Server pushes the full PR list; client handles filtering/rendering for zero-latency typing.

export const PRPicker = {
  mounted() {
    this.prs = []
    this.filtered = []
    this.highlightIndex = -1
    this.isOpen = false
    this.selectedNumbers = new Set()
    this.loading = true

    this.listbox = this.el.querySelector("[data-pr-picker-listbox]")
    this.bindInput()

    this.syncSelectedFromServer()

    // Listen for PR list from server
    this.handleEvent("prs_loaded", ({ prs }) => {
      this.prs = prs
      this.loading = false
      if (this.isOpen) this.filterAndRender()
    })

    // Click outside to close
    this.outsideClickHandler = (e) => {
      if (!this.el.contains(e.target)) this.close()
    }
    document.addEventListener("mousedown", this.outsideClickHandler)
  },

  updated() {
    // LiveView morphs chips inside the hook element, which replaces the input.
    // Re-acquire and re-bind if the DOM element changed.
    const currentInput = this.el.querySelector("[data-pr-picker-input]")
    if (currentInput !== this.input) {
      this.bindInput()
    }

    this.syncSelectedFromServer()
    if (this.isOpen) this.filterAndRender()
  },

  bindInput() {
    this.input = this.el.querySelector("[data-pr-picker-input]")

    this.input.addEventListener("input", () => {
      this.open()
      this.filterAndRender()
    })

    this.input.addEventListener("focus", () => {
      this.open()
      this.filterAndRender()
    })

    this.input.addEventListener("blur", () => {
      // Delay close to allow mousedown on dropdown items to fire first
      setTimeout(() => this.close(), 150)
    })

    this.input.addEventListener("keydown", (e) => this.handleKeydown(e))
  },

  destroyed() {
    document.removeEventListener("mousedown", this.outsideClickHandler)
  },

  syncSelectedFromServer() {
    try {
      const data = JSON.parse(this.el.dataset.selectedPrs || "[]")
      this.selectedNumbers = new Set(data.map((pr) => pr.number))
    } catch {
      this.selectedNumbers = new Set()
    }
  },

  open() {
    this.isOpen = true
    this.listbox.classList.remove("hidden")
  },

  close() {
    this.isOpen = false
    this.highlightIndex = -1
    this.listbox.classList.add("hidden")
  },

  filterAndRender() {
    const query = this.input.value.trim().toLowerCase().replace(/^#/, "")

    if (this.loading) {
      this.listbox.innerHTML = `<li class="px-3 py-2 text-sm text-gray-500">Loading PRs...</li>`
      return
    }

    const available = this.prs.filter((pr) => !this.selectedNumbers.has(pr.number))

    if (available.length === 0 && !query) {
      this.listbox.innerHTML = `<li class="px-3 py-2 text-sm text-gray-500">All PRs selected</li>`
      this.filtered = []
      return
    }

    if (query) {
      this.filtered = available.filter((pr) => {
        const num = String(pr.number)
        const title = (pr.title || "").toLowerCase()
        const author = (pr.author || "").toLowerCase()
        return num.includes(query) || title.includes(query) || author.includes(query)
      })
    } else {
      this.filtered = available
    }

    if (this.filtered.length === 0) {
      this.listbox.innerHTML = `<li class="px-3 py-2 text-sm text-gray-500">No matching PRs</li>`
      return
    }

    // Clamp highlight index
    if (this.highlightIndex >= this.filtered.length) {
      this.highlightIndex = this.filtered.length - 1
    }

    this.listbox.innerHTML = this.filtered
      .map((pr, i) => {
        const highlighted = i === this.highlightIndex
        const labels = (pr.labels || [])
          .map(
            (l) =>
              `<span class="inline-block px-1.5 py-0.5 text-xs rounded-full bg-gray-100 text-gray-600">${escapeHtml(l)}</span>`,
          )
          .join(" ")

        return `
        <li
          data-index="${i}"
          data-pr-number="${pr.number}"
          class="px-3 py-2 cursor-pointer text-sm ${highlighted ? "bg-indigo-50" : "hover:bg-gray-50"}"
        >
          <div class="flex items-center justify-between gap-2">
            <div class="flex items-center gap-2 min-w-0">
              <span class="font-mono text-indigo-600 flex-shrink-0">#${pr.number}</span>
              <span class="truncate text-gray-900">${escapeHtml(pr.title)}</span>
            </div>
            <span class="text-gray-400 flex-shrink-0 text-xs">@${escapeHtml(pr.author)}</span>
          </div>
          ${labels ? `<div class="mt-1 flex gap-1 flex-wrap">${labels}</div>` : ""}
        </li>
      `
      })
      .join("")

    // Attach mousedown handlers (not click — prevents blur before selection)
    this.listbox.querySelectorAll("li[data-pr-number]").forEach((li) => {
      li.addEventListener("mousedown", (e) => {
        e.preventDefault()
        const number = parseInt(li.dataset.prNumber)
        const pr = this.filtered.find((p) => p.number === number)
        if (pr) this.selectPR(pr)
      })
    })
  },

  selectPR(pr) {
    this.pushEvent("add_pr", { number: pr.number, title: pr.title })
    this.input.value = ""
    this.highlightIndex = -1
    // Keep focus on input for continued selection
    this.input.focus()
  },

  addRawNumber(text) {
    const cleaned = text.replace(/^[#PR-]+/i, "")
    const num = parseInt(cleaned)
    if (!num || num <= 0 || isNaN(num)) return false
    if (this.selectedNumbers.has(num)) return true // already selected, just clear input

    this.pushEvent("add_pr", { number: num, title: null })
    this.input.value = ""
    this.highlightIndex = -1
    return true
  },

  handleKeydown(e) {
    switch (e.key) {
      case "ArrowDown":
        e.preventDefault()
        if (!this.isOpen) {
          this.open()
          this.filterAndRender()
        }
        if (this.filtered.length > 0) {
          this.highlightIndex = Math.min(this.highlightIndex + 1, this.filtered.length - 1)
          this.filterAndRender()
          this.scrollHighlightIntoView()
        }
        break

      case "ArrowUp":
        e.preventDefault()
        if (this.filtered.length > 0) {
          this.highlightIndex = Math.max(this.highlightIndex - 1, 0)
          this.filterAndRender()
          this.scrollHighlightIntoView()
        }
        break

      case "Enter":
        e.preventDefault()
        if (this.highlightIndex >= 0 && this.highlightIndex < this.filtered.length) {
          this.selectPR(this.filtered[this.highlightIndex])
        } else if (this.input.value.trim()) {
          this.addRawNumber(this.input.value.trim())
        }
        break

      case "Escape":
        e.preventDefault()
        this.close()
        break

      case "Backspace":
        if (this.input.value === "") {
          e.preventDefault()
          this.pushEvent("remove_last_pr", {})
        }
        break
    }
  },

  scrollHighlightIntoView() {
    const highlighted = this.listbox.querySelector(`li[data-index="${this.highlightIndex}"]`)
    if (highlighted) highlighted.scrollIntoView({ block: "nearest" })
  },
}

function escapeHtml(text) {
  if (!text) return ""
  const div = document.createElement("div")
  div.textContent = text
  return div.innerHTML
}
