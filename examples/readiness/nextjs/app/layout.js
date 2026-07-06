import "./styles.css";

export const metadata = {
  title: "Dory Next.js readiness",
  description: "A small Dockerized Next.js app used by Dory readiness tests."
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
