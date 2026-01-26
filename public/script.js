// Add event listener for Enter key
document.addEventListener("DOMContentLoaded", () => {
    const input = document.getElementById("user-input");
    input.addEventListener("keypress", (e) => {
        if (e.key === "Enter") {
            sendMessage();
        }
    });

    // Initialize Language
    setLanguage('en');

    // Initialize Theme (check localStorage or system preference)
    initTheme();

    // Initialize Language (this will also show the welcome message)
    setLanguage('en');
});

// Theme Support
const themes = ['dark', 'light', 'dracula'];

function initTheme() {
    const savedTheme = localStorage.getItem('theme');
    if (savedTheme && themes.includes(savedTheme)) {
        setTheme(savedTheme);
    } else {
        // Check system preference
        const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
        setTheme(prefersDark ? 'dark' : 'light');
    }
}

function setTheme(theme) {
    document.body.setAttribute('data-theme', theme);
    localStorage.setItem('theme', theme);
}

function toggleTheme() {
    const currentTheme = document.body.getAttribute('data-theme');
    const currentIndex = themes.indexOf(currentTheme);
    const nextIndex = (currentIndex + 1) % themes.length;
    setTheme(themes[nextIndex]);
}

// Configuration
// Replace this with your actual Cloud Run Service URL
const API_BASE_URL = "https://ai-arda-tr-api-599610058688.asia-northeast1.run.app";

function getApiEndpoint() {
    // 1. If running on localhost, ALWAYS use local backend (relative path)
    if (window.location.hostname === "localhost" || window.location.hostname === "127.0.0.1") {
        return "/api/chat";
    }

    // 2. If running on GitHub Pages (or elsewhere), use the Cloud Run URL
    if (API_BASE_URL) {
        return `${API_BASE_URL}/api/chat`;
    }

    // 3. Fallback to relative path
    return "/api/chat";
}

// Language Support
let currentLanguage = 'en';

const translations = {
    en: {
        "header-title": "Arda's AI Construct",
        "welcome-title": "Hi, I'm Arda's AI Assistant",
        "welcome-subtitle": "Ask me anything about Arda's experience, skills, or background.",
        "input-placeholder": "Message Arda's AI...",
        "btn-experience": "Experience",
        "btn-education": "Education",
        "btn-skills": "Skills",
        "btn-visa": "Visa Status",
        "btn-about-bot": "About this Bot",
        "welcome-msg": "Hello, I am Arda's assistant. You can use me to learn about Arda's skills, experience, education, and interested opportunities. If you have an interesting position, I can contact Arda on your behalf as well.",
        "prompts": {
            "experience": "Tell me about your experience.",
            "education": "Tell me about your education.",
            "skills": "What are your technical skills?",
            "visa": "What is your visa status in Japan?",
            "about_bot": "Tell me about this bot, its architecture, and how it was built."
        }
    },
    jp: {
        "header-title": "ArdaのAIコンストラクト",
        "welcome-title": "こんにちは、ArdaのAIアシスタントです",
        "welcome-subtitle": "Ardaの経験、スキル、経歴について何でも聞いてください。",
        "input-placeholder": "メッセージを入力...",
        "btn-experience": "経歴",
        "btn-education": "学歴",
        "btn-skills": "スキル",
        "btn-visa": "ビザステータス",
        "btn-about-bot": "このボットについて",
        "welcome-msg": "こんにちは、Ardaのアシスタントです。Ardaのスキル、経験、学歴、興味のある機会について私に聞いてください。もし興味深いポジションがあれば、あなたに代わってArdaに連絡することもできます。",
        "prompts": {
            "experience": "あなたの経歴について教えてください。",
            "education": "あなたの学歴について教えてください。",
            "skills": "あなたの技術的なスキルは何ですか？",
            "visa": "日本でのビザステータスはどうなっていますか？",
            "about_bot": "このボットのアーキテクチャと、どのように構築されたか教えてください。"
        }
    }
};

function setLanguage(lang) {
    if (currentLanguage === lang) return; // Avoid reset if same language
    currentLanguage = lang;

    // Reset Context
    chatHistory = [];
    const messagesDiv = document.getElementById("messages");
    messagesDiv.innerHTML = "";
    document.getElementById("messages-container").classList.remove("has-messages");
    document.getElementById("welcome-screen").classList.remove("hidden");

    // Update UI text
    document.querySelectorAll('[data-i18n]').forEach(el => {
        const key = el.getAttribute('data-i18n');
        if (translations[lang][key]) {
            if (el.tagName === 'INPUT') {
                el.placeholder = translations[lang][key];
            } else {
                el.innerText = translations[lang][key];
            }
        }
    });

    // Update Toggle Switch State
    const toggle = document.getElementById('lang-toggle');
    if (toggle) {
        toggle.checked = (lang === 'jp');
    }

    // Show initial localized greeting
    addMessage(translations[lang]["welcome-msg"], "bot");
}

function toggleLanguage() {
    const toggle = document.getElementById('lang-toggle');
    const newLang = toggle.checked ? 'jp' : 'en';
    setLanguage(newLang);
}

function sendQuickPrompt(type) {
    const prompt = translations[currentLanguage]["prompts"][type];
    if (prompt) {
        const input = document.getElementById("user-input");
        input.value = prompt;
        sendMessage();
    }
}

function updateUIState() {
    const messagesDiv = document.getElementById("messages");
    const messagesContainer = document.getElementById("messages-container");
    const welcomeScreen = document.getElementById("welcome-screen");
    const quickTopics = document.getElementById("quick-topics");

    const hasMessages = messagesDiv.children.length > 0;

    if (hasMessages) {
        messagesContainer.classList.add("has-messages");
        welcomeScreen.classList.add("hidden");
        // Keep quick topics visible but move them visually
    } else {
        messagesContainer.classList.remove("has-messages");
        welcomeScreen.classList.remove("hidden");
    }
}

// Chat History
let chatHistory = [];

async function sendMessage() {
    const input = document.getElementById("user-input");
    const text = input.value.trim();
    if (!text) return;

    // Clear input
    input.value = "";

    // Display User Message
    addMessage(text, "user");

    // Add to history
    chatHistory.push({ role: "user", content: text });

    // Update UI to show messages
    updateUIState();

    // Show typing indicator
    const typingId = showTypingIndicator();

    try {
        const response = await fetch(getApiEndpoint(), {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                message: text,
                history: chatHistory.slice(0, -1) // Send history excluding current message
            })
        });

        const data = await response.json();

        // Remove typing indicator
        removeTypingIndicator(typingId);

        if (data.error) {
            addMessage("Error: " + data.error, "bot");
            // Remove user message from history on error to keep sync? 
            // Or just keep it. For now keeping it is fine.
        } else {
            addMessage(data.reply, "bot");
            // Add bot reply to history
            chatHistory.push({ role: "model", content: data.reply });
        }
    } catch (e) {
        removeTypingIndicator(typingId);
        addMessage("System Malfunction: Network Error", "bot");
    }
}

function showTypingIndicator() {
    const messagesDiv = document.getElementById("messages");
    const div = document.createElement("div");
    const id = "typing-" + Date.now();
    div.id = id;
    div.className = "message bot animate-fade-in";
    div.innerHTML = `
        <div class="message-avatar">A</div>
        <div class="message-content">
            <div class="typing-indicator">
                <span></span>
                <span></span>
                <span></span>
            </div>
        </div>
    `;
    messagesDiv.appendChild(div);

    // Auto-scroll to bottom
    const container = document.getElementById("messages-container");
    container.scrollTop = container.scrollHeight;

    return id;
}

function removeTypingIndicator(id) {
    const indicator = document.getElementById(id);
    if (indicator) {
        indicator.remove();
    }
}

function escapeHtml(text) {
    const map = {
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#039;'
    };
    return text.replace(/[&<>"']/g, function (m) { return map[m]; });
}

function addMessage(text, sender) {
    const messagesDiv = document.getElementById("messages");
    const div = document.createElement("div");
    div.className = "message animate-fade-in " + sender;

    // 1. Escape HTML first to prevent XSS
    let safeText = escapeHtml(text);

    // 2. Convert markdown links and plain URLs to clickable links
    let html = safeText
        // Convert markdown links: [text](url)
        .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>')
        // Convert plain URLs that aren't already part of an anchor tag
        .replace(/(?<!href="|">)(https?:\/\/[^\s<)\]]+)/g, function (match) {
            return '<a href="' + match + '" target="_blank" rel="noopener noreferrer">' + match + '</a>';
        })
        // 3. Convert newlines to <br>
        .replace(/\n/g, '<br>');

    // Build message with avatar
    const avatar = sender === 'bot' ? 'A' : 'Y';
    div.innerHTML = `
        <div class="message-avatar">${avatar}</div>
        <div class="message-content">${html}</div>
    `;

    messagesDiv.appendChild(div);

    // Auto-scroll to bottom
    const container = document.getElementById("messages-container");
    container.scrollTop = container.scrollHeight;

    // Update UI state
    updateUIState();
}
