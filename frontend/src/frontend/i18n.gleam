//// Translated UI strings and quick-topic prompts. EN/JP were ported 1:1 from
//// the `translations` object in the old `public/script.js`; TR was added
//// natively in the Lustre port.

pub type Language {
  En
  Jp
  Tr
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
        welcome_msg: "Hello, I am Arda's assistant. You can ask me about Arda's skills, experience, education, projects, and even his interests and music. If you have an interesting position, I can contact Arda on your behalf as well.",
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
        welcome_msg: "こんにちは、Ardaのアシスタントです。Ardaのスキル、経験、学歴、プロジェクト、さらには趣味や音楽活動について私に聞いてください。もし興味深いポジションがあれば、あなたに代わってArdaに連絡することもできます。",
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
    Tr ->
      Strings(
        header_title: "Arda'nın AI Konstrüktü",
        welcome_title: "Merhaba, ben Arda'nın Yapay Zekâ Asistanı",
        welcome_subtitle: "Arda'nın deneyimi, yetenekleri ya da geçmişi hakkında bana her şeyi sorabilirsiniz.",
        welcome_msg: "Merhaba, ben Arda'nın asistanıyım. Bana Arda'nın yeteneklerini, deneyimini, eğitimini, projelerini, hatta ilgi alanlarını ve müziğini sorabilirsiniz. İlginç bir pozisyonunuz varsa sizin adınıza Arda'yla iletişime de geçebilirim.",
        input_placeholder: "Mesajınızı yazın...",
        btn_experience: "Deneyim",
        btn_education: "Eğitim",
        btn_skills: "Yetenekler",
        btn_visa: "Vize Durumu",
        btn_about_bot: "Bot Hakkında",
        prompt_experience: "Bana Arda'nın iş deneyiminden bahseder misin?",
        prompt_education: "Bana Arda'nın eğitiminden bahseder misin?",
        prompt_skills: "Arda'nın teknik yetenekleri neler?",
        prompt_visa: "Arda'nın Japonya'daki vize durumu nedir?",
        prompt_about_bot: "Bana Arda'nın yapay zekâ asistanından, mimarisinden ve nasıl geliştirildiğinden bahseder misin?",
      )
  }
}
