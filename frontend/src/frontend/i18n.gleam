//// Translated UI strings and quick-topic prompts, ported 1:1 from the
//// `translations` object in the old `public/script.js`.

pub type Language {
  En
  Jp
}

pub type Strings {
  Strings(
    header_title: String,
    welcome_title: String,
    welcome_subtitle: String,
    welcome_msg: String,
    input_placeholder: String,
    btn_experience: String,
    btn_education: String,
    btn_skills: String,
    btn_visa: String,
    btn_about_bot: String,
    prompt_experience: String,
    prompt_education: String,
    prompt_skills: String,
    prompt_visa: String,
    prompt_about_bot: String,
  )
}

pub fn strings(language: Language) -> Strings {
  case language {
    En ->
      Strings(
        header_title: "Arda's AI Construct",
        welcome_title: "Hi, I'm Arda's AI Assistant",
        welcome_subtitle: "Ask me anything about Arda's experience, skills, or background.",
        welcome_msg: "Hello, I am Arda's assistant. You can use me to learn about Arda's skills, experience, education, and interested opportunities. If you have an interesting position, I can contact Arda on your behalf as well.",
        input_placeholder: "Message Arda's AI...",
        btn_experience: "Experience",
        btn_education: "Education",
        btn_skills: "Skills",
        btn_visa: "Visa Status",
        btn_about_bot: "About this Bot",
        prompt_experience: "Tell me about Arda's experience.",
        prompt_education: "Tell me about Arda's education.",
        prompt_skills: "What are Arda's technical skills?",
        prompt_visa: "What is Arda's visa status in Japan?",
        prompt_about_bot: "Tell me about Arda's AI assistant, its architecture, and how it was built.",
      )
    Jp ->
      Strings(
        header_title: "ArdaのAIコンストラクト",
        welcome_title: "こんにちは、ArdaのAIアシスタントです",
        welcome_subtitle: "Ardaの経験、スキル、経歴について何でも聞いてください。",
        welcome_msg: "こんにちは、Ardaのアシスタントです。Ardaのスキル、経験、学歴、興味のある機会について私に聞いてください。もし興味深いポジションがあれば、あなたに代わってArdaに連絡することもできます。",
        input_placeholder: "メッセージを入力...",
        btn_experience: "経歴",
        btn_education: "学歴",
        btn_skills: "スキル",
        btn_visa: "ビザステータス",
        btn_about_bot: "このボットについて",
        prompt_experience: "Ardaの経歴について教えてください。",
        prompt_education: "Ardaの学歴について教えてください。",
        prompt_skills: "Ardaの技術的なスキルは何ですか？",
        prompt_visa: "Ardaの日本でのビザステータスはどうなっていますか？",
        prompt_about_bot: "ArdaのAIアシスタント、そのアーキテクチャ、そしてどのように構築されたか教えてください。",
      )
  }
}
