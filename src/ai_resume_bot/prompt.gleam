//// System-prompt builder, ported from internal/resume/resume.go BuildPrompt.
////
//// Output is intentionally byte-for-byte identical to the Go version so that
//// Gemini responses stay stable during the migration.

import ai_resume_bot/models.{
  type AdditionalInfo, type EducationEntry, type Job, type Project,
  type ResumeData,
}
import gleam/list
import gleam/option.{None, Some}
import gleam/string_tree.{type StringTree}

pub fn build(data: ResumeData) -> String {
  let tree =
    string_tree.new()
    |> string_tree.append(
      "You are Arda's AI Assistant. You are professional, polite, and helpful. You answer questions about Arda's career, skills, and experience based on the following resume data. Your goal is to represent Arda in the best possible light to potential employers or recruiters.\n\n",
    )
    |> append_about(data)
    |> append_skills(data)
    |> append_experience(data)
    |> append_education(data)
    |> append_projects(data)
    |> string_tree.append("\n## Visa Status\n")
    |> string_tree.append("Permanent Resident (Japan)\n")
    |> string_tree.append("\n## About this Bot\n")
    |> string_tree.append(
      "This bot is an AI construct designed to represent Arda. Both the backend and the frontend are written in Gleam on the Erlang/OTP BEAM — the HTTP backend uses Wisp + Mist and runs on Google Cloud Run (Tokyo), and the chat UI is a Lustre application compiled to JavaScript. It uses Google's Gemini API for reasoning. Fun fact: the first version was 'vibe coded' with Gemini 3 in a single weekend in Go, and later ported to a full Gleam stack. You can view the source code at: https://github.com/c0ze/ai.arda.tr\n",
    )
  string_tree.to_string(tree)
}

fn append_about(tree: StringTree, data: ResumeData) -> StringTree {
  tree
  |> string_tree.append("## " <> data.about.title <> "\n")
  |> string_tree.append(data.about.paragraph1 <> "\n")
  |> string_tree.append(
    data.about.languages <> " " <> data.about.languages_content <> "\n\n",
  )
}

fn append_skills(tree: StringTree, data: ResumeData) -> StringTree {
  let tree = string_tree.append(tree, "## " <> data.skills.title <> "\n")
  let tree =
    list.fold(data.skills.technical_skills, tree, fn(acc, s) {
      string_tree.append(acc, "- " <> s <> "\n")
    })
  string_tree.append(tree, "\n")
}

fn append_experience(tree: StringTree, data: ResumeData) -> StringTree {
  let tree = string_tree.append(tree, "## " <> data.experience.title <> "\n")
  list.fold(data.experience.jobs, tree, append_job)
}

fn append_job(tree: StringTree, job: Job) -> StringTree {
  let tree =
    string_tree.append(
      tree,
      "- **" <> job.title <> " at " <> job.company <> "** [" <> job.period <> "]:\n",
    )
  let tree =
    list.fold(job.responsibilities, tree, fn(acc, resp) {
      string_tree.append(acc, "  " <> resp <> "\n")
    })
  string_tree.append(tree, "\n")
}

fn append_education(tree: StringTree, data: ResumeData) -> StringTree {
  let tree = string_tree.append(tree, "## " <> data.education.title <> "\n")
  let tree = list.fold(data.education.entries, tree, append_education_entry)
  string_tree.append(tree, "\n")
}

fn append_education_entry(tree: StringTree, edu: EducationEntry) -> StringTree {
  let tree =
    string_tree.append(
      tree,
      "- **"
        <> edu.degree
        <> "**, "
        <> edu.institution
        <> " ("
        <> edu.period
        <> "). "
        <> edu.description
        <> "\n",
    )
  case edu.additional_info {
    None -> tree
    Some(info) -> append_additional_info(tree, info)
  }
}

fn append_additional_info(tree: StringTree, info: AdditionalInfo) -> StringTree {
  let tree = string_tree.append(tree, "  **" <> info.title <> "**\n")
  list.fold(info.items, tree, fn(acc, item) {
    string_tree.append(acc, "  - " <> item <> "\n")
  })
}

fn append_projects(tree: StringTree, data: ResumeData) -> StringTree {
  let tree = string_tree.append(tree, "## " <> data.projects.title <> "\n")
  list.fold(data.projects.entries, tree, fn(acc, proj) {
    append_project(acc, proj)
  })
}

fn append_project(tree: StringTree, proj: Project) -> StringTree {
  string_tree.append(
    tree,
    "- **"
      <> proj.title
      <> "** ("
      <> proj.technologies
      <> ")\n  "
      <> proj.description
      <> "\n",
  )
}
