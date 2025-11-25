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
});

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
        "status-online": "Online",
        "input-placeholder": "Query the system...",
        "btn-send": "Send",
        "btn-experience": "Experience",
        "btn-education": "Education",
        "btn-skills": "Skills",
        "btn-visa": "Visa Status",
        "btn-about-bot": "About this Bot",
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
        "status-online": "オンライン",
        "input-placeholder": "システムに問い合わせる...",
        "btn-send": "送信",
        "btn-experience": "経歴",
        "btn-education": "学歴",
        "btn-skills": "スキル",
        "btn-visa": "ビザステータス",
        "btn-about-bot": "このボットについて",
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
    currentLanguage = lang;

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

async function sendMessage() {
    const input = document.getElementById("user-input");
    const text = input.value.trim();
    if (!text) return;

    // Clear input
    input.value = "";

    // Display User Message
    addMessage(text, "user");

    try {
        const response = await fetch(getApiEndpoint(), {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ message: text })
        });

        const data = await response.json();

        if (data.error) {
            addMessage("Error: " + data.error, "bot");
        } else {
            addMessage(data.reply, "bot");
        }
    } catch (e) {
        addMessage("System Malfunction: Network Error", "bot");
    }
}

function addMessage(text, sender) {
    const messagesDiv = document.getElementById("messages");
    const div = document.createElement("div");
    div.className = "message animate-fade-in " + sender;

    // Convert markdown links and plain URLs to clickable links
    let html = text
        // 1. Convert markdown links: [text](url)
        .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>')
        // 2. Convert plain URLs that aren't already part of an anchor tag (from step 1)
        .replace(/(?<!href="|">)(https?:\/\/[^\s<)\]]+)/g, function (match) {
            // Check if this URL was already handled by the markdown regex (it would be inside an href)
            // The negative lookbehind (?<!href="|">) handles most cases, but let's be safe
            return '<a href="' + match + '" target="_blank" rel="noopener noreferrer">' + match + '</a>';
        })
        // 3. Convert newlines to <br>
        .replace(/\n/g, '<br>');

    div.innerHTML = html;
    messagesDiv.appendChild(div);

    // Auto-scroll to bottom
    messagesDiv.scrollTop = messagesDiv.scrollHeight;
}