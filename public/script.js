// Add event listener for Enter key
document.addEventListener("DOMContentLoaded", () => {
    const input = document.getElementById("user-input");
    input.addEventListener("keypress", (e) => {
        if (e.key === "Enter") {
            sendMessage();
        }
    });
});

// Configuration
// When deploying, this should be replaced with your Cloud Run Service URL
// e.g. "https://ai-arda-tr-xyz-uc.a.run.app"
const API_BASE_URL = "https://ai-arda-tr-api-599610058688.asia-northeast1.run.app";

function getApiEndpoint() {
    // If we have a configured base URL, use it (for GitHub Pages)
    if (API_BASE_URL) {
        return `${API_BASE_URL}/api/chat`;
    }
    // Fallback to relative path (for local development where backend serves frontend)
    return "/api/chat";
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
    div.innerText = text;
    messagesDiv.appendChild(div);
    
    // Auto-scroll to bottom
    messagesDiv.scrollTop = messagesDiv.scrollHeight;
}