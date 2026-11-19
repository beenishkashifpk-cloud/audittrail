"use client";
import { useState } from "react";
import { supabase } from "@/lib/supabase";

export default function LoginPage() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [message, setMessage] = useState("");

  async function handleLogin() {
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    setMessage(error ? error.message : "Login successful");
  }

  async function handleSignUp() {
    const { error } = await supabase.auth.signUp({ email, password });
    setMessage(error ? error.message : "Account created");
  }

  return (
    <main className="mx-auto mt-20 max-w-sm space-y-3 p-4">
      <h1 className="text-2xl font-bold">AuditTrail Login</h1>
      <input
        className="w-full border p-2"
        placeholder="Email"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
      />
      <input
        className="w-full border p-2"
        type="password"
        placeholder="Password"
        value={password}
        onChange={(e) => setPassword(e.target.value)}
      />
      <button className="w-full bg-black p-2 text-white" onClick={handleLogin}>
        Login
      </button>
      <button className="w-full border p-2" onClick={handleSignUp}>
        Sign up
      </button>
      <p>{message}</p>
    </main>
  );
}