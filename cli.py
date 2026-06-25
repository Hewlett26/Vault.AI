#!/usr/bin/env python3
"""
CLI interface for Vault.AI - Terminal-based AI assistant
Usage: vault-ai [question] [options]

Simple command-line interface to interact with your Vault.AI knowledge base.
"""

import os
import sys
import json
import argparse
import requests
from datetime import datetime

API_URL = "https://vault-ai-worker.hewlett-portfolio.workers.dev"
MAX_HISTORY = 10

def print_welcome():
    print("=== Vault.AI CLI Assistant ===")
    print("Your knowledge base is ready.")
    print("Type 'help' for commands or 'exit' to quit.")
    print()

def print_help():
    print("Available commands:")
    print("  help                  Show this help message")
    print("  exit                 Exit the CLI")
    print("  <question>           Ask a question about your vault")
    print("  --question <text>    Ask a question (non-interactive)")
    print("  --workflow <type>    Specify workflow (qa, explain, quiz, mock_test, revision_plan)")
    print("  --clear              Clear conversation history")
    print()

def load_history(filename="history.json"):
    if os.path.exists(filename):
        try:
            with open(filename, "r") as f:
                return json.load(f)
        except:
            pass
    return []

def save_history(history, filename="history.json"):
    with open(filename, "w") as f:
        json.dump(history, f, indent=2)

def render_message(msg):
    if msg["role"] == "user":
        print(f"\n❓ You: {msg['text']}")
    elif msg["role"] == "assistant":
        if msg.get("workflow"):
            workflow_map = {
                "qa": "Q&A",
                "explain": "Explain", 
                "quiz": "Quiz",
                "mock_test": "Mock Test",
                "revision_plan": "Revision Plan"
            }
            workflow = workflow_map.get(msg.get("workflow", ""), msg.get("workflow", ""))
            print(f"\n🤖 Vault.AI ({workflow}):")
        else:
            print(f"\n🤖 Vault.AI:")
        
        text = msg["text"]
        if msg.get("source") == "vault+web":
            parts = text.split("\n\n**From general knowledge:**\n")
            if len(parts) == 2:
                print(f"  📓 From your notes:")
                print(f"  {parts[0]}")
                print(f"\n  🌐 From general knowledge:")
                print(f"  {parts[1]}")
            else:
                print(f"  {text}")
        else:
            print(f"  {text}")
    elif msg["role"] == "system":
        if "Error" in msg.get("text", ""):
            print(f"\n❌ Error: {msg['text']}")
        else:
            print(f"\n📌 {msg['text']}")

def interact(question, history, workflow=None):
    headers = {"Content-Type": "application/json"}
    payload = {"question": question, "history": history}
    
    if workflow:
        # For now, workflow is handled by the worker's intent classification
        # but we could potentially extend this to pass context
        pass
    
    try:
        response = requests.post(API_URL, headers=headers, json=payload, timeout=30)
        
        if response.status_code == 200:
            data = response.json()
            if data.get("error"):
                return {"role": "system", "text": data["error"]}
            
            workflow_name = data.get("workflow", "qa")
            workflow_map = {
                "qa": "Q&A",
                "explain": "Explain",
                "quiz": "Quiz", 
                "mock_test": "Mock Test",
                "revision_plan": "Revision Plan"
            }
            workflow_display = workflow_map.get(workflow_name, workflow_name)
            
            answer_msg = {
                "role": "assistant",
                "text": data["answer"],
                "workflow": workflow_display,
                "topics": data.get("topics", []),
                "source": data.get("source", "vault")
            }
            
            # Add to history
            history.append({"role": "user", "text": question})
            history.append(answer_msg)
            
            # Keep history trimmed
            if len(history) > MAX_HISTORY:
                history = history[-MAX_HISTORY:]
            
            return answer_msg
        else:
            return {"role": "system", "text": f"Request failed with status {response.status_code}: {response.text}"}
    except requests.exceptions.RequestException as e:
        return {"role": "system", "text": f"Network error: {str(e)}"}

def interactive_mode(history, workflow=None, save_history_flag=True):
    print_welcome()
    
    while True:
        try:
            question = input("\n❓ Ask a question: ").strip()
            
            if not question:
                continue
            
            if question.lower() in ["exit", "quit", "q"]:
                print("\nGoodbye!")
                break
            
            if question.lower() == "help":
                print_help()
                continue
            
            if question.lower() == "clear":
                history = []
                save_history(history)
                print("\n📝 Conversation history cleared.")
                continue
            
            print("\n🤖 Vault.AI is thinking...")
            answer = interact(question, history, workflow)
            render_message(answer)
            
            if save_history_flag:
                save_history(history)
            
        except KeyboardInterrupt:
            print("\n\nGoodbye!")
            break
        except Exception as e:
            print(f"\n❌ Error: {str(e)}")

def command_line_mode(args):
    history = load_history()
    
    question = args.question if hasattr(args, "question") and args.question else None
    workflow = args.workflow if hasattr(args, "workflow") and args.workflow else None
    save_history_flag = not args.no_history
    
    if question:
        print("🤖 Vault.AI is thinking...")
        answer = interact(question, history, workflow)
        render_message(answer)
        
        if save_history_flag:
            save_history(history)
    else:
        interactive_mode(history, workflow, save_history_flag)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Vault.AI CLI Assistant")
    parser.add_argument("question", nargs="?", help="Question to ask")
    parser.add_argument("--workflow", choices=["qa", "explain", "quiz", "mock_test", "revision_plan"], help="Override workflow type")
    parser.add_argument("--no-history", action="store_true", help="Don't save/load conversation history")
    
    args = parser.parse_args()
    
    command_line_mode(args)